# Danaview Editor: UX, Timeline UI and App Integration Design

> **Area:** Editor UX, timeline UI, app integration (Flutter side).
> **Status:** design draft for the "Editor" release. This document contains no production code. The Dart, Swift and Kotlin snippets are interface sketches.
> **Date:** 2026-10-07. **Baseline:** `main` @ `19cae59`. Flutter 3.44.2, Dart 3.12, flutter_riverpod 2.6.1, go_router 14.8.1 (versions read from `pubspec.lock`).
> **Sibling areas** (separate docs in `docs/v1.1/video-editor/design/`): Domain & project model (timeline model, commands, history, keyframes, RenderPlan), Persistence & media management (project storage, autosave, recovery, migration, media pool, relink), iOS engine (AVFoundation / Core Image / Metal / CoreText), Android engine (Media3 Transformer / CompositionPlayer / GlEffect), AI subtitles (whisper.cpp). When this document names a type that another area owns, **that area's final name wins**. §2 lists the minimum the UI needs from each area, so any gap shows up when the docs are merged.

---

## 0. Decisions at a glance

1. **New package `packages/danaview_editor`** holds the Projects screen, the Editor screen, every editor widget, and the Riverpod controllers. `danaview_features` only gets two entry points, wired through callbacks (Home edit button, player "Edit"). `danaview_features` never imports the editor. The app root (`lib/`) composes routes and providers.
2. **The layout is chosen by window size, not by device type.** There are four layouts: `compactPortrait`, `compactLandscape`, `medium`, `expanded`. On phones in portrait, tool panels open in a **non-modal docked inspector** so the preview stays visible while the user drags a slider. In the other layouts the inspector is a side pane. The modal `showDanaviewSheet` is used only for flows: export, auto captions, relink, import, project, track menu, markers.
3. **The timeline is one custom `RenderBox` (`RenderTimelineCanvas`).** It paints only the visible time window, using per-lane picture tiles. Track headers are real widgets (they have buttons and semantics). The playhead, ghosts and guides sit on their own repaint-boundary layers. During playback the **widget tree is not rebuilt per frame**.
4. **The native preview is the master clock.** `PlayheadController` is a `ValueListenable<TimeUs>` kept *outside* Riverpod state. It extrapolates native clock samples on every vsync. Scrubbing coalesces seeks so only the latest one is sent, and it ends with an exact seek on release. Every time shown on screen is quantized to the project frame grid.
5. **Every mutation goes through `EditorController.apply(EditCommand)`.** Continuous gestures (sliders, preview manipulation, clip drags, trims) run inside an `EditTransaction`. While the gesture runs, native receives *transient* overrides at most 60 Hz, latest-wins. On commit the gesture produces **one** history entry, one RenderPlan patch, and one autosave trigger.
6. **One action registry drives every way of invoking an action.** `EditorActionId` maps to label, icon, shortcuts, enablement and handler. The same registry feeds the toolbar tiles, context menus, keyboard shortcuts, semantics custom actions and the shortcut help sheet, so they cannot drift apart.
7. **Desktop is gated.** On macOS, Windows and Linux the entry points are hidden and `/projects` and `/editor/*` redirect to `/`. A flag can switch this to a "coming soon" dialog. All UI talks to a platform-neutral `EditorEngine` interface, so a desktop engine can be added later with no UI changes. Mouse, keyboard and drag-and-drop support is built now and already works on iPad and Android with a keyboard or trackpad.
8. **Player "Edit" works on local files.** Before a project is created, the app checks whether the file can be edited. Without FFmpeg, iOS cannot edit MKV, WebM or AVI. In that case the app explains why instead of silently hiding the action (§4.4).
9. **Privacy policy and terms are updated** to cover the speech-model download host, the microphone, photo-library access, files the editor creates, and third-party presets and models (§20).

---

## 1. Ground truth (verified in the repo)

| Fact | Where | Consequence for this design |
|---|---|---|
| go_router 14.8.1; flutter_riverpod 2.6.1 with `StateNotifier`; Dart 3.12, so extension types are available | `pubspec.lock` | Controllers use `StateNotifier` to match the existing code, written so a later move to Riverpod 3 `Notifier` is mechanical. Routes nest under `/` like the existing pages. |
| `_HomeHeader` is a `Row(DanaviewLogo, Expanded(title), DanaviewIconButton(settings, tonal, size 44, icon 22))` | `packages/danaview_features/lib/src/library/danaview_home_screen.dart` L474–510 | The edit button uses the identical component and sits immediately before the gear. |
| The player top bar holds back, title, lock and info. The bottom bar uses a width-priority planner that measures text with `_textWidth` | `danaview_controls_overlay.dart` L357–406, L428–575 | "Edit" is added to the trailing group of the top bar and to the "Playback" more-sheet. The editor transport reuses the measure-then-place pattern. |
| The player binds shortcuts with `Shortcuts`/`Actions` (Space/K, arrows, …) inside `Focus(autofocus)` | `danaview_player_screen.dart` L48–70, L193–237 | The editor uses the same pattern plus a text-field focus guard (§15). |
| On phones, orientation is portrait in the library and owned by the player through a **single static owner** | `danaview_player_actions.dart` `PlayerOrientation` | An owner stack is needed so the editor can open over the player and give orientation back correctly (§4.5). |
| Text scale is clamped to 0.85–1.35 app-wide | `lib/app.dart` `MediaQuery.withClampedTextScaling` | The layout planner and the overflow test matrix use exactly this range. |
| UI kit provides `DanaviewButton` (primary/secondary/tonal/ghost/destructive; sm/md/lg), `DanaviewIconButton` (circle; hit area ≥44 on touch), `DanaviewSurface`, `DanaviewSlider` (RenderBox; axis; `origin` for bipolar values), `DanaviewSegmentedControl`, `DanaviewChoiceChip`/`DanaviewChipGroup`, `DanaviewDropdown`, `DanaviewMenuAnchor`/`DanaviewMenuIconTrigger`, `showDanaviewSheet`, `showDanaviewDialog/Confirm/Prompt`, `DanaviewToast`, `DanaviewTextField`, `DanaviewSwitch(Row)`, `DanaviewListTile`/`DanaviewTileIcon`, `DanaviewEmptyState`, `DanaviewSpinner`, `DanaviewBadge`, `DanaviewSeekBar`, `DanaviewButtonBar` | `packages/danaview_ui_kit/lib/src/components/*` | All editor UI is composed from these. New *generic* pieces go into the kit with its overflow tests (§3.2). Editor-specific pieces stay in `danaview_editor`. |
| `showDanaviewSheet` is a modal `PopupRoute` with a scrim. It is keyboard-aware, defaults `maxHeightFactor` to 0.85, and is drag-dismissible | `danaview_sheet.dart` | Good for flows. Not used for live inspectors, because it would hide the preview. |
| Tokens: `DanaviewColors` (primary `#5E60EE`, primaryLight, cyan, purple, warning, success, error, hairline `0x14FFFFFF`), `DanaviewRadius` (xs 6 … xl 20), `DanaviewShadows.subtle/soft`, `DanaviewBorders.hairline` (0.8 px), `DanaviewSpacing.minTapTarget = 44`, `DanaviewBreakpoints` (560 / 900), `DanaviewColors.foregroundOn()` / `contrastRatio()` | `danaview_theme.dart`, `danaview_tokens.dart` | Editor colors derive from these tokens (§6.8). Clip-label contrast is computed, never guessed. |
| Icons are Material `Icons.*_rounded`. **`Icons.movie_edit` exists, with no rounded variant. `Icons.transition_rounded` does NOT exist.** | Flutter SDK `material/icons.dart`, checked by grep | Every icon name in this document was checked against the SDK. |
| Mobile pickers return temporary copies. `LibraryStorage.importPickedFiles` moves *only the app's own temp copies* into `Documents/Imported` and never touches user files | `danaview_data/lib/src/storage/library_storage.dart` | The editor follows the same rule. Files the editor creates never go into `Documents/`, because that folder is the "On This Device" library and is scanned for videos. |
| `LSSupportsOpeningDocumentsInPlace = true`, and `AppDelegate.handleIncomingUrl` calls `startAccessingSecurityScopedResource` | `ios/Runner/Info.plist`, `AppDelegate.swift` | A project that references a file opened in place needs a security-scoped bookmark (persistence area). The relink UI handles stale bookmarks. |
| Settings › Storage clears only the cache folder and never deletes videos | `tools/storage_usage.dart`, `tools/danaview_storage_screen.dart` | Editor caches (thumbnails, waveforms, proxies) live under the cache folder and are listed there. Project bundles are listed separately and are never cleared by "Clear cache". |
| The privacy policy and terms are structured Dart constants (`LegalSection`, `LegalBlock`, `LegalBullet`) | `more/legal_texts.dart` | §20 gives the exact block additions. |
| A pure-Dart MP4/MKV `MediaInspector` already exists | `danaview_data/lib/src/media/media_inspector.dart` | Used as a fast "can this be edited?" pre-check and to verify export output in tests. |
| Test harness: `Surface` matrix (280×500 @1.35 … 1200×800), `pumpKit`, `expectInside`, `FakePlaybackEngine` | `danaview_ui_kit/test/test_utils.dart`, `test/player_screen_test.dart` | Editor tests extend this harness (§21). |
| iOS deployment target 13.0; `UIBackgroundModes = [audio]`; no microphone or photo usage strings. Android has `READ_MEDIA_VIDEO/AUDIO` and `FOREGROUND_SERVICE` but no `RECORD_AUDIO` or `POST_NOTIFICATIONS` | `Info.plist`, `project.pbxproj`, `AndroidManifest.xml` | Declarations to add are in §20.3. Minimum OS for the editor is a runtime capability check (§4.1), not a change to the app's deployment target. |

---

## 2. Area boundaries and the contracts this UI consumes

| Area | Owns | What the UI needs from it | UI section |
|---|---|---|---|
| **Domain & model** (pure Dart) | `EditProject`, tracks, items, keyframes, transitions, `EditCommand`s and their validation, history, `dryRun` previews, geometry evaluation, RenderPlan compiler and diff | Immutable model with structural sharing (unchanged tracks and items keep their identity). Commands that return a rejection *reason*, never an exception. `dryRun` for drag ghosts. `evaluate(item, prop, t)`. `ItemGeometry.boxAt` for preview handles. `compileRenderPlan` + `diff`. Undo/redo labels | §8, §14, §16 |
| **Persistence & media** | Project bundle on disk, autosave journal, recovery, schema migration, media pool (import, dedupe, bookmarks/URI grants), availability check, relink validation, deletion semantics | `ProjectRepository` (CRUD + `watchSummaries`), `LoadedProject` carrying migration and recovery info, `MediaPoolService.import`, `availability` stream, `checkRelink` | §5, §13 |
| **iOS / Android engines** (behind one Dart `EditorEngine` interface) | Preview texture and clock, plan application, transient overrides, seek, thumbnails, waveforms, export jobs, proxies, reverse, freeze frame, voice recording, color sampling, capabilities, probe | Everything in §2.3. The UI never calls a platform channel directly | §7, §11, §17 |
| **AI subtitles** | Model manifest, download and verify, language list, PCM extraction request to native, whisper inference, segmentation, cue drafts | `TranscriptionService` (§2.4) | §12 |
| **This area (UX)** | Screens, widgets, layout, gestures, Riverpod controllers, caches *client side* (thumbnail images, waveform mipmaps, paragraphs), shortcuts, accessibility, entry points, routes, settings and storage integration, legal copy changes | n/a | all |

### 2.1 Domain contract (minimum the UI needs; Domain doc is authoritative)

```dart
// Time on the timeline clock. Microseconds; integer math only.
typedef TimeUs = int;

extension type const ProjectId(String value) {}
extension type const TrackId(String value) {}
extension type const ItemId(String value) {}   // media clips, text items, subtitle cues
extension type const MediaId(String value) {}
extension type const MarkerId(String value) {}

final class FrameRate {                         // rational, e.g. 30000/1001
  const FrameRate(this.numerator, this.denominator);
  final int numerator, denominator;
  TimeUs get frameUs;                           // rounded duration of one frame
  int frameIndexOf(TimeUs t);                   // floor
  TimeUs timeOfFrame(int index);                // exact start time of frame `index`
  TimeUs quantize(TimeUs t);                    // = timeOfFrame(frameIndexOf(t))
}

final class TimeRange { const TimeRange(this.start, this.end); final TimeUs start, end; TimeUs get duration; }

enum TrackKind { video, overlay, audio, text, subtitle }

sealed class TimelineItem { ItemId get id; TimeRange get range; }
final class MediaClip extends TimelineItem { MediaId get media; TimeRange get source; /* speed, transform, crop,
  color, lut, chroma, mask, audio, reversed, keyframes … */ }
final class TextItem extends TimelineItem { /* text, style, animation, transform, keyframes */ }
final class SubtitleCue extends TimelineItem { String get text; }

abstract interface class EditProject {
  ProjectId get id; String get name; int get revision;
  ProjectSettings get settings;            // canvas size, aspect, FrameRate, background
  List<Track> get tracks;                  // z-order defined by the Domain doc
  List<Marker> get markers;
  MediaPool get media;
  TimeUs get duration;
}

// Commands are pure: (project) -> outcome. A rejection is data, never an exception.
sealed class EditCommand { String get label; }               // e.g. 'Split clip'
final class EditOutcome { EditProject project; Set<ItemId> affected; EditRejection? rejection; }
sealed class EditRejection { }  // TrackLocked, WouldOverlap, OutOfSourceRange, BelowMinDuration,
                                // NothingAtPlayhead, UnsupportedForKind, LimitExceeded, ...
EditOutcome applyCommand(EditProject p, EditCommand c);
EditPreview dryRun(EditProject p, EditCommand c);   // must be <= 1 ms for 1000-item projects (§22)

T evaluate<T>(TimelineItem item, PropertyKey<T> key, TimeUs t);   // keyframes, linear in v1
ItemBox? boxAt(EditProject p, ItemId id, TimeUs t, {TextMetricsProvider? text}); // oriented box in canvas px

abstract interface class EditHistory {             // may live in Domain or Persistence
  bool get canUndo; bool get canRedo; String? get undoLabel; String? get redoLabel;
  List<String> recentLabels(int max);
}

RenderPlan compileRenderPlan(EditProject p, RenderTarget target);  // preview | export
RenderPlanPatch diffPlans(RenderPlan previous, RenderPlan next);
```

**UI requirements placed on Domain:** (a) a stable `id` for every visual thing the timeline paints, including transitions (`TransitionRef = (TrackId, ItemId left, ItemId right)`) and keyframes (`KeyframeRef = (ItemId, PropertyKey, TimeUs)`); (b) `dryRun` results that describe the *resulting* positions of every moved item and any `createsTrack`, so drag ghosts are exact; (c) the snap target list `snapTargets(project, exclude: Set<ItemId>) → SortedTimes` (or the raw data needed to build it); (d) `PropertyKey` metadata: display name, unit, min, max, default, `isKeyframable`, `step`. The inspector rows are generated from this metadata (§10.0).

### 2.2 Persistence contract (minimum)

```dart
abstract interface class ProjectRepository {
  Stream<List<ProjectSummary>> watchSummaries();
  Future<ProjectId> create(NewProjectSpec spec);           // probes media via EditorEngine
  Future<LoadedProject> open(ProjectId id);                // runs migration; never mutates originals
  Future<SaveReceipt> save(EditProject p, {required SaveReason reason}); // autosave | manual | exit
  Future<void> rename(ProjectId id, String name);
  Future<ProjectId> duplicate(ProjectId id, {String? name});
  Future<void> delete(ProjectId id);                       // removes only project-owned files
  Future<List<RecoverableSession>> recoverable();
  Future<EditProject> restore(RecoverableSession s);
  Future<void> discard(RecoverableSession s);
  Future<ProjectId?> findUntouchedProjectFor(String mediaPath); // reuse for player "Edit" (§4.4)
}

final class ProjectSummary { ProjectId id; String name; DateTime updatedAt; TimeUs duration;
  AspectRatio aspect; String? thumbnailPath; int missingMediaCount; bool hasRecovery;
  int bytesOwned; ProjectHealth health; /* ok | needsNewerApp | corrupt */ }

final class LoadedProject { EditProject project; MigrationInfo? migratedFrom;
  RecoverableSession? pendingRecovery; List<ProjectOpenWarning> warnings; }

abstract interface class MediaPoolService {
  Future<List<ImportOutcome>> import(List<PickedMedia> picked);   // copy or reference per platform
  Stream<MediaAvailabilityReport> watchAvailability(EditProject p);
  Future<RelinkCheck> checkRelink(MediaId id, PickedMedia candidate); // duration/size/hash compare
  Future<EditCommand> relinkCommand(MediaId id, PickedMedia candidate);
}
```

### 2.3 Engine contract (minimum; iOS and Android docs implement it, plus a fake)

```dart
abstract interface class EditorEngine {
  Future<EditorCapabilities> capabilities();
  Future<EditCompatibility> compatibility(String pathOrUri);   // fast; may use container sniffing
  Future<PreviewSession> openPreview(PreviewConfig config);
  ThumbnailSource get thumbnails;
  WaveformSource get waveforms;
  ExportService get exporter;
  MediaJobs get jobs;                    // proxies, reverse, freeze frame
  VoiceRecorder? get voiceRecorder;      // null when unsupported
  Future<List<PickedMedia>> pickMedia(MediaPickRequest request); // Photos/Gallery + Files, native pickers
  Future<FileHandoffResult> exportFile(String tempPath, FileHandoff how); // share sheet | save to Files/SAF
  Future<int> freeBytes();                                     // export / download pre-checks
}

abstract interface class MediaJobs {
  MediaJob proxy(MediaId media);                               // background, low priority
  MediaJob reverse(MediaId media, TimeRange source);           // returns a project-owned asset
  MediaJob freezeFrame(MediaId media, TimeUs sourceTime);      // returns a project-owned still
}
abstract interface class MediaJob { Stream<double> get progress; Future<AssetRef> get result; void cancel(); }

abstract interface class VoiceRecorder {
  Future<MicPermission> permission();                          // granted | denied | restricted | notDetermined
  Future<MicPermission> requestPermission();
  Future<void> openSystemSettings();
  Future<RecordingSession> start({required String projectDir});
}
abstract interface class RecordingSession {
  Stream<double> get levels;                                   // 0..1 at ~20 Hz
  Stream<RecordingInterruption> get interruptions;             // call, route change
  Future<RecordedAsset> stop();
  Future<void> cancel();
}

abstract interface class PreviewSession {
  int get textureId;
  ValueListenable<Size?> get frameSize;                 // canvas render size in px (quality-dependent)
  Future<void> setPlan(RenderPlan plan);
  Future<void> applyPatch(RenderPlanPatch patch);
  void setTransient(ItemId item, PropertyPatch patch);  // fire-and-forget, coalesced natively
  void clearTransient(ItemId item);
  Future<void> play({TimeRange? loop});
  Future<void> pause();
  Future<SeekAck> seek(TimeUs t, {SeekKind kind = SeekKind.exact}); // exact | scrub
  Future<void> setQuality(PreviewQuality q);            // auto | full | half | quarter
  Future<void> setUseProxies(bool on);
  Future<void> setEditingMode(PreviewEditingMode mode); // normal | cropSource(ItemId) | matte(ItemId)
  Future<Color?> sampleColor(ItemId item, Offset normalizedSourcePoint);
  Future<void> refresh();                               // re-render current frame (after resume)
  Stream<PreviewClock> get clock;                       // on state change + >= 4 Hz while playing
  Stream<PreviewEvent> get events;                      // firstFrame, stalled, degraded(q), surfaceLost, error
  Future<void> dispose();
}

final class PreviewClock { TimeUs time; bool playing; double rate; int seq; }
final class SeekAck { TimeUs requested; TimeUs displayedFrameTime; }

abstract interface class ThumbnailSource {
  ThumbnailHandle request(ThumbnailTileKey key, {required ThumbPriority priority});
}
abstract interface class ThumbnailHandle { Future<ThumbnailTile> get result; void cancel(); }
final class ThumbnailTileKey { MediaId media; int intervalMs; int tileIndex; int heightPx; bool proxy; }
final class ThumbnailTile { Uint8List encoded; /* JPEG strip of N frames */ int frames; int frameWidthPx; }

abstract interface class WaveformSource {
  Future<WaveformPeaks> peaks(MediaId media, {int audioStream = 0});   // min/max int8 pairs @ fixed rate
}

abstract interface class ExportService {
  Future<ExportJob> start(RenderPlan plan, ExportSettings settings, ExportDestination destination);
}
abstract interface class ExportJob { Stream<ExportProgress> get progress; Future<ExportResult> get result; Future<void> cancel(); }

final class EditorCapabilities {
  bool supported; String? unsupportedReason;          // e.g. OS too old
  bool hevcEncode; bool movContainer; Size maxExportSize; Map<int, int> maxFpsByHeight;
  bool backgroundExport; BackgroundExportKind backgroundKind; // none | timeLimited | continued(iOS 26) | foregroundService
  bool voiceRecording; bool lowMemoryDevice; DeviceTier tier; // low | mid | high
  bool proxiesRecommended;
}
```

**UI requirements placed on the engines:** clock samples include `rate` and `seq` (stale samples are dropped); seek acknowledgements report the **displayed frame time**; transient overrides never touch history or disk; `events` reports `surfaceLost` and `degraded(quality)`; thumbnail requests are cancellable; every failure arrives as a typed `EditorFailure` (§18) and never as a raw `PlatformException`.

### 2.4 AI contract (minimum)

```dart
abstract interface class TranscriptionService {
  List<TranscriptionLanguage> get languages;          // code, englishName, nativeName
  Future<SpeechModelStatus> modelStatus();            // missing | downloading(p) | ready(spec) | corrupt
  SpeechModelSpec get defaultModel;                   // name, bytes, host, sha256
  Stream<ModelDownloadProgress> downloadModel({required UserConsent consent}); // resumable
  Future<void> cancelDownload();
  Future<void> deleteModel();
  TranscriptionJob transcribe(TranscriptionRequest r); // r: plan audio source, range, language, segmentation
}
abstract interface class TranscriptionJob {
  Stream<TranscriptionProgress> get progress;          // phase: extracting | transcribing | segmenting; fraction; processedUs
  Future<List<SubtitleCueDraft>> get result;
  void cancel();
}
```

`UserConsent` is a value only the consent view can construct (a private constructor exposed through `ModelConsentView`). This makes it a compile-time guarantee that no download path skips consent.

---

## 3. Package and file layout

### 3.1 New package `packages/danaview_editor`

```
packages/danaview_editor/
  pubspec.yaml        # flutter, flutter_riverpod ^2.5.1, danaview_ui_kit, danaview_domain, danaview_data,
                      # danaview_platform, danaview_features (chrome only), <editor domain pkg>,
                      # <editor engine pkg>, <transcription pkg>, path
  lib/
    danaview_editor.dart                  # public: ProjectsScreen, EditorScreen, EditorLauncher,
                                       # EditorAvailability, editor root providers, StorageContributor impl
    src/
      app/
        editor_availability.dart       # EditorSupport, EditorAvailability, DesktopEditorPresentation
        editor_launcher.dart           # create/open/openFromPlayer; PlayerHandoff
        editor_providers.dart          # overridable roots: repository, engine, transcription, prefs
        editor_strings.dart            # all copy (centralized for later l10n)
        editor_messages.dart           # EditorFailure / EditRejection -> user message
        editor_storage_contributor.dart
      projects/
        projects_screen.dart  projects_controller.dart  project_card.dart
        new_project_sheet.dart  project_actions.dart  recovery_banner.dart
      editor/
        editor_screen.dart             # EditorScope + lifecycle + shortcuts + PopScope + scaffold
        editor_scope.dart              # InheritedWidget with ProjectId
        editor_lifecycle.dart          # app lifecycle, memory pressure, wakelock
        layout/   editor_layout.dart  editor_scaffold.dart  editor_splitter.dart  editor_top_bar.dart
        state/    editor_state.dart  editor_controller.dart  edit_transaction.dart  editor_session.dart
                  editor_events.dart  editor_clipboard.dart  playhead_controller.dart
                  transport_controller.dart  media_health_controller.dart  tasks_controller.dart
        actions/  editor_action_registry.dart  editor_actions.dart  editor_shortcuts.dart  shortcuts_sheet.dart
        preview/  preview_region.dart  preview_surface.dart  canvas_geometry.dart
                  manipulation_overlay.dart  manipulation_painter.dart  snap_guides.dart
                  crop_overlay.dart  mask_overlay.dart  eyedropper_overlay.dart  fullscreen_preview.dart
        transport/ transport_bar.dart  timecode.dart  timecode_entry.dart
        timeline/ timeline_view.dart  timeline_viewport.dart  timeline_snapshot.dart  timeline_metrics.dart
                  timeline_style.dart  ruler.dart  render_timeline_canvas.dart  timeline_tiles.dart
                  timeline_hit.dart  timeline_gestures.dart  timeline_interaction.dart  snapping.dart
                  playhead_layer.dart  track_headers.dart  track_menu_sheet.dart  timeline_semantics.dart
                  marker_sheet.dart  timeline_drop_target.dart
        caches/   thumbnail_cache.dart  waveform_cache.dart  paragraph_cache.dart
        toolbar/  tool_strip.dart  tool_rail.dart  tool_sets.dart  tool_tile.dart
        inspector/ inspector_host.dart  inspector_dock.dart  inspector_header.dart  inspector_rows.dart
                   keyframe_toggle.dart  color_field.dart
          panels/  media_panel.dart  transform_panel.dart  crop_panel.dart  speed_panel.dart
                   speed_curve_editor.dart  audio_panel.dart  voiceover_panel.dart  adjust_panel.dart
                   filters_panel.dart  chroma_panel.dart  mask_panel.dart  keyframes_panel.dart
                   text_panel.dart  font_picker.dart  subtitles_panel.dart  transitions_panel.dart
                   overlay_panel.dart  canvas_panel.dart  clip_info_panel.dart
        flows/    import_media_sheet.dart  project_sheet.dart  history_sheet.dart  tasks_sheet.dart
          export/   export_sheet.dart  export_controller.dart  export_presets.dart  export_progress_view.dart
          captions/ auto_captions_sheet.dart  auto_captions_controller.dart  language_picker.dart
                    model_consent_view.dart
          relink/   relink_sheet.dart  relink_controller.dart
      settings/
        editor_settings_screen.dart
  test/              # unit + widget + golden (§21)
  integration_test/  # on-device (§21)
```

### 3.2 Additions to `danaview_ui_kit` (generic, reusable, overflow-tested)

| Component | Purpose | Notes |
|---|---|---|
| `DanaviewProgressBar` | Determinate and indeterminate linear progress (export, download, transcription, tasks) | RenderBox like `DanaviewSlider`; semantics value "45 percent". |
| `DanaviewNumberField` | Numeric entry with unit suffix, −/+ steppers, drag-to-scrub label, min/max clamping, optional bipolar display | Built on `DanaviewTextField` and `DanaviewIconButton`. Accepts `formatter`/`parser`. |
| `DanaviewColorPicker` | HSV square, hue strip, hex field, opacity strip, swatches, optional "eyedropper" callback | All `CustomPainter`/RenderBox; no Material pickers. |
| `DanaviewDockedPanel` | Non-modal surface with the same look as `DanaviewSheet` (sheetTop radius, `surfaceElevated`, drag handle, keyboard-aware) | The editor dock builds on it; also usable elsewhere. |
| `DanaviewSearchField` | `DanaviewTextField` preset (search icon, clear, debounced `onChanged`) | Language picker, font picker, media bin. |
| `DanaviewStepIndicator` (small) | "Step 2 of 3" dots for multi-step sheets | Used by the auto-captions flow. |

### 3.3 Changes outside the new package

| File | Change |
|---|---|
| `packages/danaview_features/lib/src/library/danaview_home_screen.dart` | `DanaviewHomeScreen.onOpenEditor` and `_HomeHeader` edit button (§4.3). |
| `packages/danaview_features/lib/src/player/danaview_controls_overlay.dart` | `onEdit` callback: top-bar button and more-sheet tile (§4.4). |
| `packages/danaview_features/lib/src/player/danaview_player_screen.dart` | `onEditVideo` param, `EditVideoIntent` bound to `E`, handoff hooks. |
| `packages/danaview_features/lib/src/player/danaview_player_actions.dart` | `PlayerOrientation` → owner-stack `ScreenOrientationPolicy` (§4.5). |
| `packages/danaview_features/lib/src/controllers/player_controller.dart` | `suspendForEditor()` / `resumeAfterEditor(token)` (§4.6). |
| `packages/danaview_features/lib/chrome.dart` (new library file) | Exports `DanaviewLibraryFrame`, `DanaviewLibraryTopBar`, `DanaviewLibrarySectionHeader`, `DanaviewLibraryGroup`, `DanaviewInlineEmpty`, `danaviewLibraryInsets`, `DanaviewRefreshOnReturn` so the Projects screen shares the library chrome. |
| `packages/danaview_features/lib/src/tools/danaview_storage_screen.dart`, `storage_usage.dart` | `StorageContributor` extension point (§4.8). |
| `packages/danaview_features/lib/src/more/danaview_settings_screen.dart`, `settings_destination.dart` | Optional "Video editor" row through an `extraRows` builder (§4.8). |
| `packages/danaview_features/lib/src/more/legal_texts.dart` | Privacy and terms additions (§20). |
| `lib/router/app_router.dart` | `/projects`, `/editor/:projectId` routes with the gate (§4.2). |
| `lib/main.dart` | Overrides for editor root providers (engine, repository, transcription). |
| `ios/Runner/Info.plist`, `android/app/src/main/AndroidManifest.xml` | Usage strings and permissions (§20.3; owned jointly with the engine areas). |
| `README.md` | Architecture tree and keyboard shortcuts gain an "Editor" section. |

**Dependency rule (enforced by a test that parses the pubspecs):** `danaview_features` must not depend on `danaview_editor`. `danaview_editor` may depend on `danaview_features` only through `package:danaview_features/chrome.dart`.

---

## 4. App integration

### 4.1 Availability gating

```dart
sealed class EditorSupport { const EditorSupport(); bool get showsEntryPoints; }
final class EditorSupported extends EditorSupport { const EditorSupported(); }
final class EditorUnsupported extends EditorSupport { const EditorUnsupported(this.reason); final String reason; }
final class EditorComingSoon extends EditorSupport { const EditorComingSoon(); }   // desktop

enum DesktopEditorPresentation { hidden, comingSoon }

abstract final class EditorAvailability {
  /// Synchronous and platform-only, so routes and headers can decide without awaiting.
  static EditorSupport get platform;                       // iOS/Android -> supported; desktop -> comingSoon
  static DesktopEditorPresentation desktopPresentation = DesktopEditorPresentation.hidden;
  static bool get showsEntryPoints;                        // false on desktop when hidden
}

/// Device-level check (OS version, GPU, codecs) from EditorEngine.capabilities().
final editorDeviceSupportProvider = FutureProvider<EditorSupport>((ref) async { /* ... */ });
```

* **Platform gate (sync):** decides whether the Home button, the player action and the routes exist at all.
* **Device gate (async):** checked when the Projects screen or editor opens. If the device is unsupported (for example, the iOS minimum chosen by the iOS area, or a GPU without the required GLES/Metal features), the Projects screen shows `DanaviewEmptyState(icon: Icons.movie_edit, title: 'Video editing isn't available on this device', message: reason)`. The entry points stay visible, so the explanation is reachable.
* **Desktop:** when `hidden`, both entry points are absent and the routes redirect. When `comingSoon`, the Home button opens `DanaviewDialog(title: 'Video editor is coming to desktop', message: 'Editing is available on iPhone, iPad and Android today.')`.

### 4.2 Routes (`lib/router/app_router.dart`)

```dart
String projectsLocation() => '/projects';
String editorLocation(ProjectId id, {TimeUs? at}) =>
    '/editor/${Uri.encodeComponent(id.value)}${at == null ? '' : '?t=$at'}';

String? _editorGate(BuildContext context, GoRouterState state) =>
    EditorAvailability.platform is EditorSupported ? null : '/';

// Under the existing GoRoute('/') routes list:
GoRoute(
  path: 'projects', name: 'projects', redirect: _editorGate,
  builder: (context, state) => ProjectsScreen(
    onBack: () => _back(context),
    onOpenProject: (id) => context.push(editorLocation(id)),
  ),
),
GoRoute(
  path: 'editor/:projectId', name: 'editor', redirect: _editorGate,
  builder: (context, state) {
    final id = ProjectId(state.pathParameters['projectId']!);
    final at = int.tryParse(state.uri.queryParameters['t'] ?? '');
    return EditorScreen(key: ValueKey(id), projectId: id, initialPlayhead: at, onClose: () => _back(context));
  },
),
```

* **Unknown project id** (stale deep link, deleted project): `EditorScreen` shows `DanaviewEmptyState('This project isn't available', 'It may have been deleted.', actions: [Go to Projects])`. It never throws.
* **Back-swipe:** the editor wraps its content in `PopScope(canPop: false, onPopInvokedWithResult: …)`. This disables the iOS edge back-swipe (`ModalRoute.popGestureEnabled` is false when `popDisposition == doNotPop`), which would otherwise fight horizontal timeline drags near the left edge. Back is handled explicitly (§4.7). *Verify on 3.44 (see §24).*
* **Navigation from the editor:** "Play exported video" uses the existing queue (`danaviewPlayItems`) and then `context.push('/player')`.

### 4.3 Home header edit button

`DanaviewHomeScreen` gets `final VoidCallback? onOpenEditor;` (doc comment: *Shows a video-editor button immediately before the settings button when set*). `_HomeHeader(onOpenEditor:, onOpenSettings:)`:

```dart
if (onOpenEditor != null) ...[
  const SizedBox(width: DanaviewSpacing.sm),
  DanaviewIconButton(
    icon: Icons.movie_edit,                 // exists in the SDK; no _rounded variant
    variant: DanaviewIconButtonVariant.tonal,  // same as settings, for visual parity
    size: 44, iconSize: 22,
    tooltip: 'Video editor',
    semanticLabel: 'Open video editor',
    onPressed: onOpenEditor,
  ),
],
if (onOpenSettings != null) ...[ /* existing gear */ ],
```

Router: `onOpenEditor: EditorAvailability.showsEntryPoints ? () => context.push(projectsLocation()) : null`.
**Overflow check (280 px wide at 1.35×):** with a 16 px gutter on each side, the content width is 248. Logo 36 + gap 12 + edit 44 + gap 8 + gear 44 + gap 8 = 152 fixed, leaving 96 px for the `Expanded` "Danaview" title (ellipsized). The Home overflow test is extended to cover this (UX-03).

### 4.4 Player "Edit" action

**Data type (in `danaview_features`, plain data):**

```dart
@immutable
class PlayerEditRequest { const PlayerEditRequest({required this.media, required this.position, required this.wasPlaying});
  final MediaRef media; final Duration position; final bool wasPlaying; }
```

**Entry points (only when `onEdit != null`, `playerHasMedia(state)`, `!media.isRemote`, and status ≠ error):**

| Place | Widget |
|---|---|
| Top bar, first item of the trailing group (before lock) | `DanaviewIconButton(icon: Icons.movie_edit, iconSize: 20, tooltip: 'Edit video (E)', semanticLabel: 'Edit this video')` |
| "Playback" more sheet, above Queue | `DanaviewListTile(leading: DanaviewTileIcon(Icons.movie_edit), title: 'Edit video', subtitle: 'Trim, add text, captions and more', showChevron: true)` |
| Keyboard (when supported) | `SingleActivator(LogicalKeyboardKey.keyE)` → `EditVideoIntent` |

Remote streams: the action is **hidden**, because the user cannot fix that. Local files in a format the editor can't use: the action is **shown**, and tapping it explains why (see step 2 below).
Top-bar width check at 280 px: back 44 + edit 44 + lock 44 + info 44 + paddings 16 = 192, leaving 88 px for the ellipsized title. The existing player overflow tests get a 280 px case with the new button.

**Flow (`EditorLauncher.openFromPlayer(PlayerEditRequest r, BuildContext context)`):**

1. `PlayerController.pause()`. `position` is taken from the request (the player's last snapshot).
2. **Compatibility pre-check.** Both steps must answer within 300 ms:
   * `File(media.pathOrUri).exists()`. If false, show the existing player toast "Couldn't find this video. It may have been moved or deleted."
   * `EditorEngine.compatibility(path)`. The engine may use `MediaInspector` for the container and codec plus a platform table. If unsupported, show `DanaviewDialog(icon: Icons.movie_edit, title: "This video can't be edited", message: compat.reason)`. Example copy for iOS + MKV: *"Danaview can play MKV files, but iPhone and iPad can only edit MP4, MOV and M4V videos. Convert it to MP4 to edit it."* The single action is "OK".
3. **Reuse or create:**
   * If `ProjectRepository.findUntouchedProjectFor(path)` returns an id (a project created from this file with no edits yet), reuse it. Tapping Edit twice must not litter the Projects list.
   * Otherwise `create(NewProjectSpec.fromMedia(path, name: media.title, initialPlayhead: position))`. The canvas size, aspect and frame rate come from the probe; rotation metadata is respected.
   * If this step takes longer than 300 ms, show a non-dismissible `DanaviewDialog` with `DanaviewSpinner` and the text "Preparing editor…". Failures map through §18 into a dialog.
4. `PlayerHandoff.suspend(mode)` (§4.6).
5. `context.push(editorLocation(id, at: position.inMicroseconds))`. The editor opens with an exact seek to `frameRate.quantize(at)`.
6. When the editor route pops, `PlayerHandoff.resume()` runs: orientation owner restored (§4.5), playback stays paused at the original position, and the controls are revealed.

`danaview_features` stays editor-agnostic: `DanaviewPlayerScreen(onEditVideo: ValueChanged<PlayerEditRequest>?)` and the router passes `(r) => ref.read(editorLauncherProvider).openFromPlayer(r, context)`.

### 4.5 Orientation owner stack (refactor of `PlayerOrientation`)

The single static `_owner` breaks this sequence: the editor opens over the player, then pops, and the player is left with no owner, so the phone snaps to portrait while the player is visible.

```dart
enum OrientationMode { appDefault, followDevice /* player */, free /* editor */ }

abstract final class ScreenOrientationPolicy {
  /// Pushes [owner] with [mode]; the top of the stack decides preferred orientations.
  static Future<void> enter(Object owner, OrientationMode mode);
  /// Removes [owner] wherever it is in the stack, then re-applies the new top (or app default).
  static Future<void> release(Object owner);
  static Future<void> toggle(Object owner, Orientation current);   // player rotate button
}
```

`PlayerOrientation.enter/release/toggle` become thin wrappers, so the existing call sites and tests keep working. The editor uses `OrientationMode.free` on phones (portrait and landscape follow the device). Tablets are already free.

### 4.6 Player ↔ editor engine handoff

Two engines decoding at once (libmpv in the player plus AVFoundation or Media3 in the editor) can exhaust hardware decoder instances or RAM on low-tier Android.

```dart
enum PlayerHandoffMode { pause, release }

final class PlayerResumeToken { MediaRef media; Duration position; bool released; }

extension PlayerControllerEditorHandoff on PlayerController {
  Future<PlayerResumeToken> suspendForEditor(PlayerHandoffMode mode); // pause; save resume point; if release: stop()
  Future<void> resumeAfterEditor(PlayerResumeToken token);            // if released: reopen paused at position
}
```

Mode selection: `release` when `EditorCapabilities.lowMemoryDevice`, otherwise `pause` (instant return). Both modes are covered by tests. The Home "Now playing" card must keep showing the item while it is released: the queue keeps the item, and only the engine stops.

### 4.7 Editor lifecycle

| Event | Behavior |
|---|---|
| Route enter | `ScreenOrientationPolicy.enter(this, free)`; `EditorController.open()`; preview created; wakelock off until playing |
| Close button / Android back / Esc (nothing to dismiss) | Order: (1) close the open inspector or flow; (2) clear the selection; (3) `controller.close()` flushes the save (shows "Saving…" in the top bar; waits up to 3 s); on failure ask: "Couldn't save your latest changes. Leave anyway? Your last autosave is kept." → pop |
| `AppLifecycleState.inactive` | Pause playback, commit or cancel any open transaction (a gesture interrupted by a call is cancelled), request autosave |
| `hidden` / `paused` | Flush the save immediately; keep the preview session but stop the clock listener |
| `resumed` | `preview.refresh()` and re-seek to the playhead (Android `SurfaceProducer` may have lost its surface; see §24) |
| `didHaveMemoryPressure` | Thumbnail memory cache trimmed to 25%; paragraph cache cleared; `PreviewSession` asked to drop caches |
| Playback / export / transcription / model download | `PlatformBridge.setSleepInhibited(true)` while active |

### 4.8 Settings and Storage integration (no `danaview_features` → `danaview_editor` dependency)

```dart
// danaview_features (new)
abstract interface class StorageContributor {
  String get title;                         // 'Video editor projects', 'Editor cache', 'Speech model'
  String get subtitle;                      // explains what clearing does
  Future<FolderUsage> measure();
  StorageClearAction? get clearAction;      // null => not clearable here (projects: managed in Projects)
}
final storageContributorsProvider = Provider<List<StorageContributor>>((ref) => const []);
```

`danaview_editor` provides three contributors, overridden in `main.dart`:

| Contributor | Location | Clear action |
|---|---|---|
| Editor projects | App support dir, never `Documents` | None. The tile has a chevron that opens Projects |
| Editor cache | Cache dir: thumbnails, waveforms, proxies, previews | Confirm "Clear editor cache"; regenerated as needed |
| Speech model | Models dir | "Delete speech model" (confirm; offline captions unavailable until downloaded again) |

The Settings screen gets an optional "Video editor" row (`SettingsDestination.editor`, `/settings/editor`, hidden when the editor is unavailable). It opens `EditorSettingsScreen`:

| Setting | Values |
|---|---|
| Proxy media | Auto (recommended) / Always / Off |
| Default preview quality | Auto / Full / Half |
| Center playhead on touch | On / Off |
| Snapping haptics | On / Off |
| Default new-project aspect | Match first clip / 16:9 / 9:16 / 1:1 / 4:5 |
| Auto captions | Model status, size, "Delete" |

Preferences are stored through the existing `SessionRepository`/`AppStorage` pattern (shared_preferences keys prefixed `editor.`).

---

## 5. Projects screen

### 5.1 Layout

```
┌──────────────────────────────────────────────┐
│ ‹  Projects                         [+ New] │  DanaviewLibraryTopBar (actions: DanaviewButton.primary sm)
├──────────────────────────────────────────────┤
│ ┌ Recovery banner (only when needed) ──────┐ │  DanaviewSurface, warning-tinted icon
│ │ ⚠ "Goa trip" closed unexpectedly.        │ │
│ │   [Restore changes]   [Discard]          │ │
│ └──────────────────────────────────────────┘ │
│ Recent ▾                         (search 🔍) │  sort dropdown; search appears at > 8 projects
│ ┌────────┐ ┌────────┐ ┌────────┐            │  responsive grid
│ │ thumb  │ │ thumb  │ │ thumb  │            │
│ │Goa trip│ │Reel 03 │ │Untitled│            │
│ │1:24·9:16│ │0:31·1:1│ │0:00·16:9│          │
│ │⚠ 2 missing│ │      │ │        │          │
│ └────────┘ └────────┘ └────────┘            │
│ Projects use 1.4 GB · Manage storage ›       │  footer (DanaviewPressable → /settings/storage)
└──────────────────────────────────────────────┘
```

* Grid: `columns = clamp(floor((width - 2·gutter + 12) / (minCard 160 + 12)), 2, 6)`. Below 340 px wide, one column with a horizontal card variant (thumbnail 96 px on the left, text on the right). Card thumbnail area is fixed 16:9; the project aspect is letterboxed inside it on a `surfaceElevatedHigher` background.
* Card text: name (`headline`, 1 line, ellipsis); meta line (`caption`, 1 line, ellipsis): `formatClock(duration) · aspect label · Edited 2 h ago`. Badges (`DanaviewBadge`, wrap): `Missing media` (error), `Recovered` (warning), `Needs update` (when the schema is newer than the app).
* Card menu (`DanaviewMenuIconTrigger(Icons.more_horiz_rounded)`, also on long-press and right-click): Open, Rename, Duplicate, Delete. Thumbnail via `Image.file(cacheWidth: cardWidth·dpr)`, with a placeholder `DanaviewTileIcon(Icons.movie_edit)` when there is no thumbnail.

### 5.2 Actions and copy

| Action | UI | Result |
|---|---|---|
| New | `NewProjectSheet` (§5.3) | Creates and opens the editor |
| Open | Tap card | `onOpenProject(id)`. A project in `needsNewerApp` state shows a dialog instead: "This project was made with a newer version of Danaview. Update Danaview to open it." Unchanged on disk. |
| Rename | `showDanaviewPrompt(title: 'Rename project', initialValue: name, validator: 1–80 chars after trim)` | Toast "Renamed to "…"" |
| Duplicate | Immediate; name `"<name> copy"`, then `"<name> copy 2"` … | New card animates in; toast "Duplicated" |
| Delete | `showDanaviewConfirm(title: 'Delete "<name>"?', message: 'The project and media made in it (voice recordings, freeze frames, reversed clips) are removed. Your original videos, photos and music stay where they are.', destructive: true)` | Toast with **Undo** for 5 s: deletion is deferred until the toast expires, then committed via the repository |
| Restore (banner) | `ProjectRepository.restore` → opens editor | The card gets a `Recovered` badge until the next manual save |
| Discard (banner) | Confirm "Discard unsaved changes from that session? The last saved version is kept." | Banner disappears |

### 5.3 New project sheet

`showDanaviewSheet(title: 'New project')`, scroll-controlled:

1. **Add media** (`DanaviewButtonBar`): `Photos` (iOS) or `Gallery` (Android) with `Icons.photo_library_rounded`, and `Files` with `Icons.folder_open_rounded`. Both call `EditorEngine.pickMedia(MediaPickRequest(kinds: {video, image, audio}, multiple: true))`. Picked items are listed as removable chips with thumbnail and duration.
2. **Format:** `DanaviewSegmentedControl` (wraps to a `DanaviewChipGroup` under 360 px): Auto (from first video), 16:9, 9:16, 1:1, 4:5, 4:3, 21:9.
3. **Name** (optional): `DanaviewTextField`, hint "Untitled project".
4. Primary button "Create" (disabled while importing). A secondary "Start empty" creates a project with no media.

While importing, each chip shows `DanaviewProgressBar`. If a copy is needed (iOS Photos), a hint reads "Videos from Photos are copied into Danaview so your project keeps working." Errors stay inline on the chip: "Couldn't add this file: format not supported", with a remove (×) button.

### 5.4 State

```dart
@immutable
class ProjectsState {
  final AsyncValue<List<ProjectSummary>> projects;
  final List<RecoverableSession> recoverable;
  final ProjectSort sort;                 // recent | name
  final String query;
  final Set<ProjectId> pendingDelete;     // hidden while the undo toast is up
  final int totalBytes;
}

class ProjectsController extends StateNotifier<ProjectsState> {
  ProjectsController(this._repo, this._prefs);
  Future<ProjectId> create(NewProjectSpec spec);
  Future<void> rename(ProjectId id, String name);
  Future<ProjectId> duplicate(ProjectId id);
  void requestDelete(ProjectId id);       // hides immediately; commits after the undo window
  void undoDelete(ProjectId id);
  Future<void> commitPendingDeletes();    // also on dispose / app hide
  Future<ProjectId> restore(RecoverableSession s);
  Future<void> discard(RecoverableSession s);
  void setSort(ProjectSort s); void setQuery(String q);
}
final projectsControllerProvider = StateNotifierProvider.autoDispose<ProjectsController, ProjectsState>(...);
```

---

## 6. Editor screen layout system

### 6.1 Regions

| Region | Contents | Owner widget |
|---|---|---|
| Top bar | Close, project title button (name + save status), undo, redo, export | `EditorTopBar` |
| Preview | Native `Texture` letterboxed to the canvas aspect, manipulation overlay, status overlays | `PreviewRegion` |
| Transport | Play/pause, timecode, frame step, edit-point jump, adaptive extras, "more" | `TransportBar` |
| Timeline | Ruler, track headers, lanes, playhead, markers; drop target | `TimelineView` |
| Tools | Top-level tool tabs, or context tools for the selection | `ToolStrip` (bottom) / `ToolRail` (side) |
| Inspector | Panel for the active tool or selection | `InspectorDock` (compactPortrait) / `InspectorPane` (others) |

### 6.2 Layout kinds (`EditorLayoutSpec.resolve`)

```dart
enum EditorLayoutKind { compactPortrait, compactLandscape, medium, expanded }
enum InspectorPlacement { dockBottom, sidePane }

@immutable
class EditorLayoutSpec {
  static EditorLayoutSpec resolve({
    required Size size,             // MediaQuery.sizeOf
    required EdgeInsets padding,    // safe area
    required EdgeInsets viewInsets, // keyboard
    required TextScaler textScaler, // already clamped 0.85–1.35 by the app
    required bool touch,
    required double splitRatio,     // user splitter preference for this kind
    required bool inspectorOpen,
  });
  final EditorLayoutKind kind;
  final double topBarHeight, transportHeight, toolStripHeight, railWidth;
  final double paneWidth;           // side pane (0 when docked)
  final double headerWidth;         // track header column
  final double previewHeight, timelineHeight;
  final InspectorPlacement inspectorPlacement;
  final double dockHeight;          // compactPortrait only
  final DegradeStep degrade;        // which fallback steps were applied (tests assert on this)
}
```

**Kind rules** (usable size = size minus safe area):
* `compactLandscape` when `usable.height < 520 && usable.width > usable.height` (phones in landscape and short windows).
* else `compactPortrait` when `usable.width < 600` (phones in portrait, iPad Slide Over and narrow Split View).
* else `medium` when `usable.width < 1000` (tablet portrait, wide Split View).
* else `expanded`.

**Text-scale-derived sizes**, with `s = textScaler.scale(1)` and every row height computed from its scaled font so a 1.35 scale never clips:

| Size | Formula | s=1.0 | s=1.35 |
|---|---|---|---|
| Top bar (two-line title) | `max(52, 8 + 15·s·1.25 + 12·s·1.2)` | 52 | 55 |
| Top bar (one line, compactLandscape) | `max(44, 12 + 15·s·1.25)` | 44 | 44 |
| Transport | `max(44, 16 + 13·s·1.3)` | 44 | 44 |
| Tool tile (icon + label) | `8 + 24 + 4 + 11·s·1.25 + 8` | 58 → **60** | 63 → **64** |
| Ruler | `max(24, 8 + 11·s·1.2)` | 24 | 26 |
| Lane: video/overlay | compact 52 / normal 60 / large 76 | | |
| Lane: audio | 40 / 48 / 64 | | |
| Lane: text/subtitle | `max(32, 12 + 11·s·1.3)` | 32 | 32 |
| Track header width | compact 44; medium 132; expanded 168 (pointer) / 220 (touch) | | |
| Side pane width | `clamp(usable.width·0.34, 280, 380)` | | |

**Space allocation (compactPortrait):** `fixed = topBar + transport + toolStrip + splitter(12)`. The remainder `R` splits by the user ratio `r ∈ [0.30, 0.70]` (default 0.5): preview `R·r`, timeline `R·(1−r)`. Minimums: preview ≥ 140, timeline ≥ `ruler + mainLane + 0.5·nextLane` (≈ 102).

**Deterministic degradation ladder.** Each step is applied only when the minimums can't be met. Steps are applied in order and recorded in `spec.degrade` for tests:
1. The timeline drops to its minimum.
2. The preview drops to 112.
3. Tool tiles become icon-only (48 high). Labels move to tooltips and semantics; the active tool's name shows in the dock header.
4. The transport row merges into the top bar: play/pause and compact time replace the title. The title is still reachable through the project sheet.
5. (Keyboard visible, compactPortrait, text editing) The preview hides and the docked text panel takes the space above the keyboard (§10.8).

Worked example, 280×500 at 1.35 (the narrowest test surface): fixed = 55 + 44 + 64 + 12 = 175; R = 325; preview 162, timeline 163. No degradation. Worked example, 320×480 with keyboard (240) during text editing: step 5 applies.

### 6.3 Wireframes

**compactPortrait (phone portrait), nothing selected:**
```
┌─────────────────────────────────────┐
│ ✕  Goa trip ▾              ↶  ↷  ⤒ │ top bar: title button + "Saved"; Export icon < 360 px, label ≥ 360
│    Saved                            │
├─────────────────────────────────────┤
│                                     │
│          PREVIEW (fit, 9:16)        │ flex (splitter ratio)
│                                     │
├─────────────────────────────────────┤
│ 00:12:15 / 01:30:00    ⏮  ▶  ⏭   ⋯ │ transport (planner: time, frame ±1, play, more)
├──────────────── ═══ ────────────────┤ splitter (12; drag; double-tap resets)
│ ⚙│0:10    0:11    0:12│   0:13     │ ruler (corner: timeline options)
│ T│      [Title text]  │             │ text lane
│ ▣│[clip A][clip B ───┼──][clip C]   │ main video lane (thumbnails), + between clips
│ ♪│[~~~~~~ music ~~~~~┼~~~~~]        │ audio lane (waveform)
│ +│                    │             │ add-track row
├─────────────────────────────────────┤
│ Media Audio Text Captions Overlay Effects Filters Transitions Format │ tool strip (scrolls)
└─────────────────────────────────────┘
```
The center line is the **center-locked playhead** (touch default): the timeline scrolls under it and scrolling scrubs.

**compactPortrait, video clip selected:** the tool strip switches to context tools, with a leading "✕ Clip" chip that clears the selection (§9.2).

**compactPortrait, inspector open (Adjust):**
```
│          PREVIEW (shrinks, ≥140)    │
├─────────────────────────────────────┤
│ 00:12:15 / 01:30:00    ⏮  ▶  ⏭   ⋯ │
│ ⚙│ ruler            │              │ timeline reduced to ruler + the selected item's lane
│ ▣│[clip A][sel B ───┼──]           │  (auto-scrolled vertically; ≥ 76 px)
╞═════════════════════════════════════╡ dock (drag handle: default ↔ expanded 85%)
│ ‹  Adjust               ⟲   ◇   ✓  │ header: back, title, reset, keyframe-all, done
│ [ Light ][ Color ][ Detail ]        │ segmented sections
│ Exposure          ◇  ───●──── +12   │ InspectorSliderRow
│ Brightness        ◇  ────●───   0   │
│ … (scrolls)                         │
└─────────────────────────────────────┘
```

**compactLandscape (phone landscape):**
```
┌────────────────────────────────────────────────────────────────────┐
│ ✕  Goa trip · Saved                              ↶    ↷   [Export] │ 44
├──────────────────────────────────────┬─────────────────────────────┤
│                                      │ Pane: tools grid / context  │
│            PREVIEW (fit)             │ tools / inspector (scrolls) │ flex
│                                      │ width clamp(34%, 280, 380)  │
├──────────────────────────────────────┴─────────────────────────────┤
│ ▶ 00:12:15 / 01:30:00  ⏮ ⏭           ◫ snap  ⇥ ripple   −  +   ⋯  │ transport 40
│ ⚙│ ruler                          │                                │
│ ▣│ lanes …  (min ruler + 52 + 32)  │                                │ ≥ 110
└────────────────────────────────────────────────────────────────────┘
```
On an 844×390 phone (usable ≈ 750×369): 44 + preview 175 + 40 + 110 = 369. If the user drags the splitter to favor the timeline, the preview can go down to 112.

**medium (tablet portrait):** top bar 56; preview + side pane (320) in one row; transport full width; timeline (default 45% of height) with 132 px headers.

**expanded (tablet landscape, future desktop):**
```
┌───────────────────────────────────────────────────────────────────────────┐
│ ‹  Goa trip · Saved                       ↶  ↷        ⋯           [Export] │ 56
├─────┬─────────────────────┬───────────────────────────────────────────────┤
│Rail │ Pane (340)          │                PREVIEW                        │
│ 76  │ Media bin / tool    │                                               │
│     │ content / inspector ├───────────────────────────────────────────────┤
│     │                     │ ▶ 00:12:15 / 01:30:00  ⏮ ⏭  ✚marker  ◫ ⇥ − + ⛶ │
├─────┴─────────────────────┴───────────────────────────────────────────────┤
│ hdr 168/220 │ ruler + lanes  (splitter; default 42%)                       │
└───────────────────────────────────────────────────────────────────────────┘
```

### 6.4 Top bar

`[close][title button][spacer][undo][redo][export]`
* **Close:** `Icons.close_rounded` on compact kinds, `Icons.arrow_back_ios_new_rounded` on medium and expanded. Tooltip "Close editor".
* **Title button:** `DanaviewPressable` wrapping a column of name (`headline`, 1 line, ellipsis) and status (`caption`, 1 line): `Saved` · `Saving…` · `Edited` · `Couldn't save · Retry` (error color, tappable). A trailing `Icons.expand_more_rounded` hints that it opens the **Project sheet**: rename, Format (canvas), Save now (shows `⌘S`/`Ctrl+S` when a keyboard is attached), Media in project, Keyboard shortcuts, Background tasks.
* **Undo / Redo:** `DanaviewIconButton(Icons.undo_rounded / Icons.redo_rounded)`, disabled when the history doesn't allow it. Tooltip carries the label: "Undo Split clip (⌘Z)". **Long-press on undo** opens the history sheet (§14.2).
* **Export:** at width ≥ 360, `DanaviewButton.primary(size: sm, label: 'Export', icon: Icons.upload_rounded)`. Otherwise an icon-only `DanaviewIconButton(variant: primary, icon: Icons.upload_rounded, tooltip: 'Export')`, which is round because it is a single icon, per the owner's rule.
* Width at 280: close 44 + undo 44 + redo 44 + export 44 + paddings 16 = 192, leaving 88 for the title button.

### 6.5 Splitter

`EditorSplitter`: a 12 px tall hit area (24 px on touch, extending into the neighbors) with a 36×4 grip (`0x33FFFFFF`, like the sheet drag handle). Dragging changes `splitRatio` (clamped to the minimums). Double-tap resets it to the default. Semantics: an adjustable slider "Preview size, 50 percent" with increase and decrease actions. The ratio is persisted per `EditorLayoutKind` under the key `editor.split.<kind>`.

### 6.6 Keyboard insets

* `EditorScaffold` reads `MediaQuery.viewInsetsOf(context).bottom` and recomputes the spec. The dock sits above the keyboard (bottom padding = viewInsets). The preview shrinks first, then step 5 applies.
* Sheets (`showDanaviewSheet`) already handle keyboards.

### 6.7 No-overflow rules applied in every editor region

1. Every `Row` holding text gives that text `Expanded`/`Flexible` with `maxLines` and ellipsis. Numeric labels use `FontFeature.tabularFigures()` and widths **measured at the current text scale**, using `TextPainter` the same way `_textWidth` does in the player.
2. Bars that hold variable-count controls use a **priority planner**: mandatory items, optional items by priority while they fit, and the rest in "more". This is the same algorithm as the player's `_buildControlsRow`, extracted into `PriorityRowPlanner` in `danaview_editor/lib/src/editor/layout/`.
3. Toolstrips scroll horizontally and never wrap. Tile width is `clamp(measuredLabel + 16, 64, 112)`.
4. Panels have a fixed header and a scrollable body (`CustomScrollView`). No panel assumes a height.
5. Painted text in the timeline is clipped to its clip's rect and ellipsized by the paragraph (`ParagraphStyle(maxLines: 1, ellipsis: '…')`).
6. Every dialog and sheet comes from the kit (already overflow-tested). Editor-specific sheet bodies get their own matrix tests (§19.2).

### 6.8 Editor color tokens (`timeline_style.dart`, derived from `DanaviewColors`)

| Token | Value | Use |
|---|---|---|
| `laneBackground` | `DanaviewColors.background` | lanes |
| `laneSeparator` | `DanaviewColors.hairlineSubtle` | 1 px between lanes |
| `videoAccent` | `DanaviewColors.primary` | main video lane header icon, selected-tool tint |
| `overlayAccent` | `DanaviewColors.purple` | overlay/PiP clips (3 px top stripe) |
| `audioFill` / `audioWave` | `cyan @ 0x29` / `cyan @ 0xCC` | audio clips |
| `textFill` | `warning @ 0x33` | text clips |
| `subtitleFill` | `success @ 0x29` | subtitle cues |
| `selection` | `DanaviewColors.primaryLight` | 2 px inner outline; handles' accent |
| `playhead` | `DanaviewColors.textPrimary` | 2 px line + knob |
| `snapGuide` | `DanaviewColors.primaryLight` | 1 px guide + time pill |
| `offline` | `error @ 0x33` + hatch `0x14FFFFFF` | missing media |
| `marker` (default) | `DanaviewColors.warning` | ruler flags; 6 user colors |

Clip labels sit on an `overlayDark` chip, so the white text contrast is ≥ 7:1 whatever the thumbnail shows. Colors never carry meaning alone: every lane kind has an icon and a name, and badges have glyphs.

---

## 7. Preview, transport and direct manipulation

### 7.1 Preview surface

* `PreviewSurface` = `ColoredBox(black)` → `Center` → `AspectRatio(canvas aspect)` → `Texture(textureId: session.textureId, filterQuality: FilterQuality.low)`. Native renders at the quality-dependent size (`frameSize`), and Flutter scales the texture to the view rect.
* Status overlays (centered, `IgnorePointer` except buttons):
  * `starting`: `DanaviewSpinner`.
  * `failed`: `DanaviewInlineEmpty` with "Preview stopped" and a "Restart preview" button (re-creates the session).
  * `offline media at playhead`: a hatched card "Media missing" with a "Relink…" button.
  * `degraded`: a small `DanaviewBadge('Preview ½')` top-right with tooltip "Preview quality was lowered to keep playback smooth. Export is unaffected."
* Background color: the project's canvas background. Letterbox areas outside the canvas are pure black so the canvas edge is visible.
* Semantics: `Semantics(label: 'Preview, 1080 by 1920, ${timecode}', image: true)`, plus the manipulation overlay's own semantics (§19.1).

### 7.2 Canvas geometry

```dart
@immutable
class CanvasGeometry {
  CanvasGeometry({required Size canvasPx, required Rect viewRect}); // viewRect = letterboxed rect in the overlay
  final Size canvasPx; final Rect viewRect;
  double get scale;                                   // viewRect.width / canvasPx.width
  Offset toView(Offset canvas); Offset toCanvas(Offset view);
  Path boxPath(ItemBox box);                          // oriented rect in view coords
  bool hits(ItemBox box, Offset view, {double slop = 0});
}

@immutable
class ItemBox { final Offset center; final Size size; final double rotation; final bool flipX, flipY; } // canvas px
```

Boxes come from the Domain `boxAt(project, item, t)`, which evaluates keyframes at the playhead. For text items the box needs text metrics; see §24 Q3 (text-rendering ownership). The UI requires a `TextMetricsProvider` that returns the same box the renderer will draw.

### 7.3 Manipulation overlay (move / scale / rotate)

A single `RawGestureDetector` uses a `ScaleGestureRecognizer`, which reports one- and two-finger pans together with `scale` and `rotation`. Trackpad pinch on iPad and Android works through PointerPanZoom events on the same recognizer. A `TapGestureRecognizer` and a `LongPressGestureRecognizer` cover the rest.

| Gesture | Target | Effect | History label |
|---|---|---|---|
| Tap | Visual item at playhead | Select it. Repeated taps at the same point cycle through overlapping items, top-most first | n/a |
| Tap | Empty canvas | Clear selection | n/a |
| One-finger drag | Selected item (or unselected: selects it first) | Move; snaps (§7.4) | "Move" |
| Two-finger pinch / rotate | Anywhere while an item is selected | Scale around the box center (focal translation applied); rotate by `details.rotation`; snaps rotation | "Scale" / "Rotate" / "Transform" |
| Drag corner handle | Selected | Uniform scale from the center | "Scale" |
| Drag rotate handle (28 px above the top edge; flips below near the top of the view) | Selected | Rotate; snaps to 0/45/90/… within 3° | "Rotate" |
| Double-tap | Text item | Opens the text panel focused on the text field | n/a |
| Long-press | Item | Context menu: Duplicate, Delete, Bring forward, Send backward, Reset transform, Keyframe at playhead | per action |

**Pipeline per gesture:**
* **Start:** `tx = controller.beginTransaction('Move')`, then `geometry` and `startTransform = evaluate(item, transform, playhead)`.
* **Update:** compute `newTransform` in canvas space, then `tx.update(SetTransform(item, newTransform, at: keyframed ? playhead : null))`. The controller (a) updates its working project, (b) calls `preview.setTransient(item, patch)` once per frame, latest-wins, and (c) the overlay repaints the handles from the *working* project.
* **End:** `tx.commit()`. **Cancel** (a second gesture interrupts, app goes inactive, or Esc): `tx.cancel()` → `preview.clearTransient(item)`.

**Keyframed property:** when position, scale or rotation already has keyframes, the drag writes a keyframe at the frame-quantized playhead (it creates one if none exists there). The label becomes "Move (keyframe)" and the keyframe toggle in the inspector lights up.

**Handles (`ManipulationPainter`):**
* Oriented outline: 1.5 px `primaryLight`.
* Corner handles: 12 px white circles with `DanaviewShadows.subtle`, hit radius 22 px on touch and 10 on pointer.
* Rotate handle: 24 px `surfaceElevatedHigher` circle with `Icons.rotate_right_rounded` drawn as a glyph.
* Size and angle readout pill while dragging: "W 64% · 32°".

All handles stay inside the preview rect: a handle that would land outside is clamped and given an offset leader line.

### 7.4 Snapping in the preview

* Targets: canvas center X and Y, canvas edges, and the title-safe margins (5% inset) when the "Safe area guides" toggle is on in the timeline options menu.
* Threshold: 6 view px on pointer devices, 10 on touch. Rotation magnet: ±3° around multiples of 45°.
* While snapped, a 1 px `primaryLight` line spans the canvas. `HapticFeedback.selectionClick()` fires when a snap *engages*, not continuously.
* Holding Alt/Option (with a keyboard) disables snapping. The timeline options menu has a global toggle.

### 7.5 Crop, mask and eyedropper modes

* **Crop** (tool "Crop"): `preview.setEditingMode(cropSource(item))` makes native show the clip's *source* frame untransformed. `CropOverlay` draws the crop rect with 8 handles (corners and edges) and a rule-of-thirds grid. Dragging inside moves the rect.
  * Aspect chips: Free, Original, 16:9, 9:16, 1:1, 4:5, 4:3. Rotate 90° and flip H/V buttons.
  * Values are normalized source coordinates. Reset and Done; Done commits "Crop" and leaves crop mode.
* **Mask** (§10.10): the shape is drawn in the composite view relative to the clip box, with handles for center move, size (corners), rotation, and a feather handle (small diamond outside the right edge; outward distance = feather). An invert toggle lives in the panel.
* **Eyedropper** (chroma key and color fields): a reticle with a 40 px swatch follows the finger. `preview.sampleColor(item, sourcePoint)` is throttled to 15 Hz while dragging, and release commits. For chroma key the sample comes from the **pre-key** source.

### 7.6 Transport bar

The `PriorityRowPlanner` places items in this order (mandatory first):

| Priority | Item | Widget | Shortcut |
|---|---|---|---|
| M | Play/pause | `DanaviewIconButton(Icons.play_arrow_rounded / pause_rounded, 28)` | Space, K |
| M | Timecode `00:12:15 / 01:30:00` (compact fallback `0:12 / 1:30`) | `TimecodeText` in `DanaviewPressable`; tap opens timecode entry | — |
| 1 | Frame back / forward | `Icons.keyboard_arrow_left_rounded` / `keyboard_arrow_right_rounded` (repeat on hold, 8 Hz after 400 ms) | ← / → |
| 2 | Previous / next edit point | `Icons.first_page_rounded` / `last_page_rounded` | ↑ / ↓ |
| 3 | Add marker | `Icons.bookmark_add_rounded` | M |
| 4 | Snapping toggle | `Icons.vertical_align_center_rounded` (selected state) | N |
| 5 | Ripple toggle | `Icons.swap_horiz_rounded` (selected state) | R |
| 6 | Zoom out / in | `Icons.zoom_out_rounded`, `Icons.zoom_in_rounded` | ⌘− / ⌘= |
| 7 | Fullscreen preview | `Icons.fullscreen_rounded` | F |
| 8 | Preview quality | `DanaviewMenuIconTrigger(Icons.hd_rounded)` | — |
| M (if anything is hidden) | More | `Icons.more_horiz_rounded` → `DanaviewMenuAnchor` with the hidden items | — |

**Timecode** formats as `mm:ss:ff`, or `h:mm:ss:ff` at one hour and above. Frames use the project frame rate (drop-frame display is not used in v1). Typing in **timecode entry** (`showDanaviewPrompt`) accepts `1:23`, `1:23:12`, `83.5s`, `+2s`, `-10f`, and seeks to the frame-quantized result. Invalid input returns an inline validator message such as "Use minutes:seconds or seconds, like 1:23 or 83.5s".

### 7.7 Fullscreen preview and quality

* **Fullscreen:** a pushed `PageRoute` with a fade transition. It hosts a second `Texture` widget with the same `textureId` while the editor's surface is hidden (one texture id can back several `Texture` widgets).
  * Controls: play/pause, `DanaviewSeekBar` (reused; markers passed as `chapters`), time, a close button, and rotate on phones (through `ScreenOrientationPolicy.toggle`).
  * `SystemUiMode.immersiveSticky`. Tap toggles the controls; they auto-hide after 3 s while playing, like the player overlay.
* **Quality menu:**
  * Auto (default): native lowers quality when dropped frames exceed 10% over 2 s.
  * Full, Half, Quarter.
  * Toggle "Use optimized media (proxies)".
  * Footer note: "Only affects the preview. Exports always use full quality and original media."

### 7.8 Playhead sync with the native clock

```dart
class PlayheadController extends ChangeNotifier implements ValueListenable<TimeUs> {
  PlayheadController({required FrameRate frameRate, required TickerProvider vsync});
  TimeUs get value;                 // frame-quantized, what the UI shows
  bool get isScrubbing;
  void attach(PreviewSession s);    // listens to s.clock
  void beginScrub();                // pauses playback if playing
  void scrubTo(TimeUs t);           // UI updates immediately; seek coalesced (latest-wins)
  void endScrub();                  // final exact seek; adopts SeekAck.displayedFrameTime
  Future<void> seekExact(TimeUs t); // frame step, keyboard, marker jump, timecode entry
}
```

* **Playing:** each `PreviewClock` sample `(time, rate, seq)` is stamped on receipt with a monotonic `Stopwatch` time. A `Ticker` computes `t = sample.time + elapsedSince(sampleStamp)·rate` on every vsync and quantizes it to the frame. It notifies **only when the frame index changes**. If an incoming sample differs from the extrapolation by more than one frame, the playhead snaps to the sample; otherwise it slews by at most ½ frame per tick, so the playhead never jitters backward.
* **Scrubbing:** at most one seek is in flight. While a seek is pending, new targets replace `pendingTarget`, and when the ack arrives the latest pending target is sent. Kind `scrub` (fast, may show the nearest decodable frame) is used during the drag and `exact` on release. The final displayed time is `SeekAck.displayedFrameTime`, which makes seeking frame-accurate.
* **Stale samples:** samples with `seq` older than the last seek are ignored, so a late "playing at 0:10" can't yank the playhead after the user seeked.
* **Consumers:** the timeline playhead layer (`markNeedsPaint` only), `TimecodeText` (rebuilds a single `Text` at most once per frame change), keyframe toggles (derived `ValueListenable<bool>` that notifies only on change), and the center-locked viewport follow. **Nothing in `EditorState` changes per playback frame.**

---

## 8. Timeline

### 8.1 Composition

```
TimelineView (ConsumerStatefulWidget)
 ├─ TimelineDropTarget (DragTarget<MediaDragData>)            // in-app media bin drags
 │   └─ RawGestureDetector (TimelineGestureArbiter recognizers) // scroll, zoom, taps, long-press, drags
 │       └─ Row
 │           ├─ TrackHeaderColumn (widgets; SingleChildScrollView(NeverScrollable), controller follows viewport.scrollY)
 │           └─ Stack
 │               ├─ RepaintBoundary(TimelineRulerBox)          // ticks + markers (RenderBox)
 │               ├─ RepaintBoundary(TimelineCanvas)            // RenderTimelineCanvas: lanes + clips
 │               ├─ RepaintBoundary(TimelineInteractionLayer)  // ghosts, guides, marquee, trim pills
 │               └─ RepaintBoundary(PlayheadLayer)             // 2 px line + knob
 └─ Semantics (scroll actions, live region for drags)
```

The single gesture surface covers both the headers and the lanes, so a vertical drag on a header scrolls the tracks. Taps on header buttons still win in the gesture arena because `DanaviewPressable`'s tap recognizer accepts on pointer-up with no movement.

### 8.2 View model: `TimelineSnapshot`

```dart
@immutable
class TimelineSnapshot {
  final int revision; final FrameRate frameRate; final TimeUs duration;
  final List<LaneModel> lanes;            // display order, top -> bottom (§8.3)
  final List<MarkerModel> markers;        // sorted by time
  final Map<MediaId, MediaVisual> media;  // hasVideo, hasAudio, offline, proxyReady, aspect
}

@immutable
class LaneModel {
  final TrackId id; final TrackKind kind; final String name; final bool isMain;
  final bool locked, hidden, muted, solo; final LaneHeight height;
  final List<ItemModel> items;            // sorted by start, non-overlapping
  final List<TransitionModel> transitions;
  final int revision;                     // bumps only when this lane changed -> tile invalidation
}

@immutable
class ItemModel {
  final ItemId id; final TimeUs start, end; final ItemVisualKind kind; // video|image|audio|text|cue|freeze|gap
  final String label; final MediaId? media; final TimeUs sourceIn; final double avgSpeed;
  final int badges;                        // bitmask: speed, ramp, reversed, muted, fx, color, lut, chroma, mask, kf
  final List<TimeUs> keyframeTimes;        // union over properties (for diamonds)
  final bool offline;
}
```

`TimelineSnapshotBuilder.build(previous, project)` reuses the previous `LaneModel` and `ItemModel` instances whenever the Domain objects are `identical`. The cost is proportional to what changed (a split touches one lane). It is unit-tested for identity reuse.

### 8.3 Lane order and track semantics

* **Top → bottom:** subtitle lanes, text lanes, overlay lanes (front-most first), main video lane, extra video lanes, then audio lanes. Visual lanes appear in compositing order, so "higher on screen = on top in the video". The Domain doc owns the z-order; the UI only maps it.
* **Main video lane:** always present. Gaps on it are drawn hatched and are selectable ("Delete gap").
* **Track flags (header buttons and the track menu):**

| Lane kind | Visibility | Mute | Solo | Lock |
|---|---|---|---|---|
| video / overlay | ✓ (eye) | ✓ (if media has audio) | ✓ | ✓ |
| audio | n/a | ✓ | ✓ | ✓ |
| text / subtitle | ✓ | n/a | n/a | ✓ |

When any lane is soloed, only soloed lanes are audible. Solo does not affect what is visible. Locked lanes can't be selected or edited: their clips are drawn at 60% opacity with a hatch, and a tap shows the toast "This track is locked" with an "Unlock" action. Hidden lanes are drawn at 40% opacity.

### 8.4 Coordinates, zoom and scroll (`TimelineViewportController`)

```dart
class TimelineViewportController extends ChangeNotifier {
  double get pxPerSecond;          // zoom
  double get scrollTimeSec;        // time at the left edge (double for smooth motion)
  double get scrollY;              // vertical lane offset (px)
  bool get centerLocked;           // touch default; pointer default false
  double xOf(TimeUs t); TimeUs timeAt(double x);
  void zoomBy(double factor, {required double anchorX});   // keeps time under anchor fixed
  void zoomToFit();                                        // whole project in view, 5% margin
  void scrollByPx(double dx, double dy);
  void fling(Velocity v);          // platform-appropriate ScrollSimulation per axis, driven by a Ticker
  void ensureVisible(TimeRange r); // auto-follow, reveal selection
  void setViewport(Size size, double headerWidth);
}
```

* **Zoom range:**
  * Minimum: `viewportWidth / max(duration + 10 s, 30 s)` (whole project plus margin).
  * Maximum: one frame = 48 px, which is `fps·48` px/s (1440 px/s at 30 fps).
  * Keyboard and button zoom steps are ×1.5 / ÷1.5. Pinch is continuous.
* **Zoom anchor:** the focal point on pointer devices and in free mode. In center-locked mode the anchor is always the playhead at the center.
* **Scroll bounds:** center-locked: `[−viewport/2, duration + viewport/2]`, so time 0 and the end can reach the center line. Free mode: `[−24 px, duration + 30% viewport]`.
* **Center-locked mode (touch default):** the playhead line is fixed at the center. Horizontal scrolling *is* scrubbing: it calls `playhead.scrubTo(timeAt(center))` and pauses playback if it was playing. During playback the viewport follows `playhead.value` each frame. Each frame only shifts the content layers' offsets (§17.2); nothing is rebuilt.
* **Free mode (pointer default; toggle in the timeline options):** clicking or dragging the ruler seeks or scrubs, and the playhead knob is draggable. During playback, auto-follow pages when the playhead passes 90% of the width, scrolling so it sits at 10%.
* **Mouse and trackpad:** wheel scrolls lanes vertically; Shift+wheel or a horizontal trackpad scroll moves time; Ctrl/⌘+wheel and trackpad pinch zoom around the cursor.

### 8.5 Ruler

* **Tick ladder** (seconds unless noted): `[1f, 2f, 5f, 10f, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]`. The major interval is the smallest ladder value whose pixel spacing is at least `measuredLabelWidth + 24`. Minor ticks subdivide by 5 (or 2 when the spacing would fall below 8 px).
* **Labels:** `m:ss` for second intervals and `m:ss:ff` for frame intervals. Paragraphs are cached in an LRU (256 entries) keyed by `(text, scale)`.
* **Markers:** a 10 px flag in the marker color. Tap selects the marker and opens the marker sheet (name, color among 6, note, delete, jump). Drag moves the marker (snaps to frames and playhead). The sheet is also reachable from the long-press menu.
* **Ruler corner cell** (above the headers): `DanaviewMenuIconTrigger(Icons.tune_rounded)` "Timeline options" with these entries:
  * Snapping ✓ (N)
  * Ripple editing ✓ (R)
  * Center playhead
  * Track height: Compact / Normal / Large
  * Show thumbnails ✓
  * Show waveforms ✓
  * Safe area guides
  * Add track › Video / Overlay / Audio / Text / Subtitles

  A small dot badge on the button shows when ripple is on.

### 8.6 Painting (`RenderTimelineCanvas`)

```dart
class TimelineCanvas extends LeafRenderObjectWidget {
  const TimelineCanvas({required this.snapshot, required this.viewport, required this.selection,
    required this.thumbnails, required this.waveforms, required this.paragraphs,
    required this.style, required this.metrics, required this.interaction});
}

class RenderTimelineCanvas extends RenderBox {
  // Listens to viewport, thumbnail/waveform arrival (filtered to visible keys), interaction changes.
  @override bool get isRepaintBoundary => true;
  TimelineHit hitTestTimeline(Offset local);      // used by recognizers (§8.8)
  @override void paint(PaintingContext context, Offset offset);
  @override void describeSemanticsConfiguration(SemanticsConfiguration c);
  @override void assembleSemanticsNode(SemanticsNode node, SemanticsConfiguration c, Iterable<SemanticsNode> children);
}
```

**Visible window:** `[timeAt(0) − overscan, timeAt(width) + overscan]` with overscan = ½ viewport. Visible lanes come from `scrollY` and the lane heights. For each visible lane, a binary search over `items` finds the first item ending after the window start, and iteration stops past the window end. Cost is O(log n + visible).

**Per item (in this order):**
1. **Body:** `RRect` with radius 6 (`DanaviewRadius.xs`), filled with the kind color.
2. **Content:**
   * video/image/freeze: a thumbnail strip (§17.3) drawn with `drawImageRect` per visible frame cell. A missing cell is a flat `surfaceElevatedHigher` rectangle (no shimmer animation).
   * audio, and video with audio when the lane is "Large": waveform lines from the mip level closest to the current px/s (§17.4), drawn in one `drawRawPoints(PointMode.lines)` call.
   * text/cue: single-line text excerpt.
3. **Label chip** at the top-left (only when the clip is at least 72 px wide): name, plus duration when at least 120 px wide; `overlayDark` background.
4. **Badges** at the top-right (only when at least 48 px wide): speed `2x` or ramp glyph, reversed, muted, `fx`, LUT, chroma, mask, keyframes. Each badge is a 14 px glyph; when they don't fit they collapse to a count.
5. **State overlays:** selected (2 px inner `selection` outline, plus trim handles drawn by the interaction layer), locked (hatch), hidden (opacity), offline (hatched `offline` fill + `Icons.link_off_rounded` glyph + "Missing").
6. **Keyframe diamonds** (selected item, or every item while the Keyframes tool is open): a 7 px diamond row 4 px above the bottom edge. A diamond at the playhead is filled.
7. **Transitions:**
   * An existing transition at a cut draws a 20×20 "bowtie" chip centered on the cut.
   * Main lane with no transition at a cut: a 16 px "+" circle (`Icons.add_rounded` glyph), shown only when both neighbors are at least 40 px wide. Its hit area is 32 px, or 44 px on touch, centered on the cut.
   * Tapping either opens the Transitions panel for that cut.

**Text:** `ui.Paragraph`s are built with `DanaviewFonts.family`, `maxLines: 1`, `ellipsis: '…'`, and laid out at `clipWidth − padding`. They are cached by `(text, widthBucket(8 px), style)`.

### 8.7 Interaction layer and playhead layer

* **`TimelineInteractionController` (ChangeNotifier)** holds the transient interaction state: `DragGhost` (item ids, proposed lane and time, valid flag, `createsTrack`), `TrimGhost` (item, edge, new edge time, delta), `SnapGuide` (time, kind), `Marquee` (rect), `DropGhost` (media, lane, time). The interaction layer repaints from it. The canvas does not repaint during drags unless ripple shifts other items; those shifted positions come from `dryRun` and are drawn in the interaction layer as offsets.
* **Playhead layer:** a 2 px line spanning the full height and a 12×18 knob in the ruler (free mode). It repaints on `playhead` changes only. In center-locked mode the line is static and the content moves.

### 8.8 Gestures (`TimelineGestureArbiter`)

On pointer-down the arbiter calls `canvas.hitTestTimeline(position)`, which returns a `TimelineHit`:

```dart
sealed class TimelineHit {}
final class HitTrimHandle extends TimelineHit { ItemId item; TrimEdge edge; }
final class HitKeyframe extends TimelineHit { KeyframeRef ref; }
final class HitTransition extends TimelineHit { TransitionRef ref; bool isAddButton; }
final class HitPlayheadKnob extends TimelineHit {}
final class HitMarker extends TimelineHit { MarkerId id; }
final class HitRuler extends TimelineHit { TimeUs time; }
final class HitItem extends TimelineHit { ItemId item; TrackId lane; TimeUs time; bool selected; }
final class HitGap extends TimelineHit { TrackId lane; TimeRange gap; }
final class HitEmpty extends TimelineHit { TrackId? lane; TimeUs time; }
```

Recognizers (custom subclasses gate entry with `isPointerAllowed`):

| Recognizer | Allowed when the hit is | Claims | Does |
|---|---|---|---|
| `_EagerHandleDrag` (horizontal drag; resolves *accepted* on pointer-down) | trim handle, keyframe, playhead knob, marker | immediately (beats scroll) | trim / move keyframe / scrub / move marker |
| `_PointerItemDrag` (mouse / stylus only) | item that is already selected | after slop | move clip(s) |
| `LongPressGestureRecognizer` (touch, 350 ms) | item, empty lane, marker, keyframe | on timeout | **item:** lift (haptic `mediumImpact`). Moving drags the clip; releasing without movement opens the context menu. **Empty:** menu (Paste here, Add media here, Add text here) |
| `TapGestureRecognizer` | any | on up | item: select (Shift/⌘ toggles on keyboards, or always toggles in multi-select mode); ruler: seek (free mode); transition: select and open the panel; gap: select gap; empty: clear selection |
| `ScaleGestureRecognizer` | any (fallback) | after slop | 1 pointer: axis-locked pan (dominant axis decided at slop: horizontal = time scroll/scrub, vertical = lanes). 2 pointers: horizontal pinch zoom (`details.horizontalScale`, anchored per §8.4). End: per-axis fling |
| `_MarqueeDrag` (mouse only, primary button) | empty lane | after slop | rubber-band select (adds with Shift) |
| Secondary click (`onSecondaryTapUp`) | any | n/a | the same context menu as long-press |

**Hover (pointer):** `MouseRegion` cursors: `SystemMouseCursors.resizeLeftRight` on trim handles, `grab`/`grabbing` on selected items, `click` on "+" and markers. Hovering a clip shows a tooltip-like name and duration pill after 600 ms.

### 8.9 Move, trim, split, snapping, ripple

**Snap index:** built at drag start by `SnapIndex.build(snapshot, exclude: draggedIds, playhead, markers)` as one sorted `Int64List` of times plus a parallel kinds list. Lookup is a binary search for the nearest time to each candidate edge: a move checks both the start and the end of the dragged group. The threshold is 8 px on pointer devices and 12 on touch, converted to time at the current zoom. The guide line, time pill and a `selectionClick` on each *new* engagement are shown. Alt/Option disables it temporarily, and the **N** key or the options menu toggles it.

**Move:**
1. The drag computes `proposedStart = original + Δt`, then snaps.
2. It calls `dryRun(project, MoveItems(ids, delta, toLane, ripple: modes.ripple))`.
3. The ghost renders the returned positions. When the domain reports an overlap that the policy can't resolve on that lane, the ghost shows a warning outline and a "New track" pill (the Domain policy decides between auto-new-track and rejection; the UI renders whatever `EditPreview` says).
4. Drop commits `MoveItems`. Vertical moves are allowed only for a single-lane selection into a lane of a compatible kind.
5. **Auto-scroll:** within 48 px of a horizontal edge, a ticker scrolls at a speed proportional to depth (up to 1.5 viewports per second). The same applies vertically.

**Trim:**
* Handles are 12 px wide bars inside the clip edges. Their hit area extends 12 px outward (20 on touch). On clips narrower than 3 handles, handles are drawn outside the clip.
* The drag updates `TrimItem(item, edge, newTime, ripple)` through `dryRun`. It is limited by the source range for video and audio; images, text and cues are unlimited. The minimum duration is 1 frame (Domain).
* The pill shows "In +0:01:05 · 0:04:12" (delta and new duration). With ripple on, following items on the lane shift live in the ghost. Commit applies "Trim clip".

**Split:** at `frameRate.quantize(playhead)`. Target: the selected items under the playhead; if none are selected, the unlocked main-lane item under the playhead; if there is none, the toast "Move the playhead over a clip to split it." Haptic `lightImpact`.

**Ripple mode:** toggled by **R**, the transport, or the options menu, and persisted per project. It affects insert, move, delete and trim on the lanes involved. The Domain owns the exact semantics; the UI renders the `dryRun` results.

**Delete vs ripple delete:**
* "Delete" leaves a gap, unless ripple mode is on.
* "Ripple delete" always closes the gap. It is shown as a separate tool and menu item, and bound to Shift+Delete.
* Selecting a gap offers "Delete gap".

**Multi-select:**
* Touch: the long-press menu has "Select multiple", which enters multi-select mode. A banner pill over the timeline shows "3 selected · Select all on track · Done". Taps toggle.
* Keyboard and pointer: Shift-click or ⌘/Ctrl-click toggles; the marquee adds; ⌘/Ctrl+A selects all.
* Multi-selection supports move (time only, across lanes, keeping relative offsets), delete, ripple delete, duplicate, copy, cut and "Move to track…" (single-kind selections).

### 8.10 Track headers and track menu

* **Compact (44 px):** a 44×lane-height `DanaviewPressable` with the kind icon and tiny status glyphs (lock, eye-off, muted, solo "S") drawn in its corner. Tap opens the **track menu sheet**:
  * Name (rename), then switches for Visible, Locked, Muted, Solo, per §8.3.
  * Height: Compact / Normal / Large.
  * Move up / Move down.
  * Add track above / below.
  * Select all on track.
  * Subtitles: Style, Import SRT/VTT, Export SRT/VTT, Burn into video.
  * Delete track (confirm when it isn't empty).
* **Medium/expanded (132–220 px):** kind icon, name (ellipsis), and inline `DanaviewIconButton(size: 32)` toggles. On touch the hit area grows to 44, as the component already does. The full menu is still available through the icon button.
* Kind icons: video `Icons.movie_rounded`, overlay `Icons.picture_in_picture_alt_rounded`, audio `Icons.music_note_rounded`, text `Icons.text_fields_rounded`, subtitle `Icons.subtitles_rounded`.

### 8.11 Clip thumbnails, waveforms, metadata

* Thumbnails and waveforms are lazy (visible window plus overscan), cached in memory and on disk (§17.3–17.4). They are shown or hidden through the timeline options.
* **Clip info panel** (context tool "Info"): file name, location (path, ellipsized in the middle, with a "Copy path" button on keyboard devices), source resolution, frame rate, codec, rotation, duration, used range (in/out), speed and resulting duration, file size, proxy status, availability (Missing → "Relink…"). Values come from the media pool and probe.

---

## 9. Bottom toolbar, tool tabs and the inspector host

### 9.1 Top-level tools (nothing selected)

| Tool | Icon | Opens | Notes |
|---|---|---|---|
| Media | `Icons.video_library_rounded` | Media panel (§10.1) | import, media bin, add at playhead |
| Audio | `Icons.music_note_rounded` | Audio tab: Add music, Record voiceover, Extract audio (needs a video selected), Sounds from Files | |
| Text | `Icons.text_fields_rounded` | Adds a text item at the playhead and opens the text panel | |
| Captions | `Icons.closed_caption_rounded` | Subtitles panel: Auto captions, Add caption, Import SRT/VTT, Style, Export | |
| Overlay | `Icons.picture_in_picture_alt_rounded` | Add video or image overlay (PiP) | |
| Effects | `Icons.tune_rounded` | Adjust panel | auto-targets the main-lane clip under the playhead (selects it, toast "Editing clip at playhead") |
| Filters | `Icons.palette_rounded` | Filters & LUT panel | same auto-target |
| Transitions | `Icons.compare_rounded` | Transitions panel for the cut nearest the playhead | toast "Add at least two clips to use transitions" when there is none |
| Format | `Icons.aspect_ratio_rounded` | Canvas panel: aspect, background, frame rate | |

### 9.2 Context tools (driven by `ToolSets.forSelection(EditorSelection, EditProject)`)

| Selection | Tools (in order; strip scrolls) |
|---|---|
| Video clip (main or extra lane) | Split, Speed, Volume, Transform, Crop, Adjust, Filters, Chroma key, Mask, Keyframes, Animation*, Reverse, Freeze, Extract audio, Replace, Duplicate, Copy, Ripple delete, Delete, Info |
| Overlay (video) | the Video set + Bring forward / Send backward (lane order), Blend opacity is in Transform |
| Image / freeze frame | Split, Duration, Transform, Crop, Adjust, Filters, Chroma key, Mask, Keyframes, Replace, Duplicate, Copy, Delete, Info |
| Audio clip | Split, Volume, Fades, Speed, Keyframes (volume), Replace, Duplicate, Copy, Ripple delete, Delete, Info |
| Text | Edit, Font, Style, Animation, Transform, Keyframes, Duplicate, Copy, Delete |
| Subtitle cue | Edit text, Timing, Split, Merge with next, Style (track), Position (track), Delete |
| Multi-selection | Duplicate, Copy, Cut, Move to track…, Ripple delete, Delete |
| Transition | Type, Duration, Direction, Apply to all, Remove |
| Gap (main lane) | Delete gap |
| Marker | Rename, Color, Note, Delete |

\* "Animation" on video is **reserved and hidden** in v1. It is not in the owner's list; text animations are.

Each tile is `ToolTile(spec: EditorActionSpec)` with icon, label, enablement, and semantics `button + label + hint`. A disabled tile stays visible with 40% opacity (`DanaviewColors.disabled`). Tapping it explains why in a toast, for example "Reverse isn't available for images." The leading chip is `[✕ Video clip]` (`DanaviewChoiceChip`, selected, `Icons.close_rounded`) and clears the selection.

### 9.3 Inspector host

```dart
sealed class InspectorRoute {
  const InspectorRoute();
  ItemId? get target;
}
// one subclass per panel: MediaInspector, TransformInspector(item), CropInspector(item),
// SpeedInspector(item), AudioInspector(item, focus: volume|fades), VoiceoverInspector, AdjustInspector(item),
// FiltersInspector(item), ChromaInspector(item), MaskInspector(item), KeyframesInspector(item),
// TextInspector(item, tab), SubtitlesInspector(track, cue?), TransitionInspector(ref), OverlayInspector,
// CanvasInspector, ClipInfoInspector(item), MarkerInspector(id)
```

* `InspectorHost` hosts the panel in either the `InspectorDock` (compactPortrait) or the side pane.
* **Header (`InspectorHeader`):**
  * back (`Icons.arrow_back_ios_new_rounded`, returns to the tool list)
  * title (1 line, ellipsis)
  * reset (`Icons.settings_backup_restore_rounded`, confirm only when keyframes would be removed)
  * keyframe-all toggle (when the panel has keyframable rows)
  * done (`Icons.check_rounded`)
* **Dock heights:** default `max(240, timelineHeight + toolStripHeight − 76)`, expanded to 85% of the screen by dragging the handle (`DanaviewDockedPanel`). The body scrolls.
* **Changing selection while a panel is open:** the panel re-targets if the new item supports it, or closes and shows the new context tools if it doesn't.
* **Row widgets (`inspector_rows.dart`), all built on kit components:**
  * `InspectorSliderRow`: label, keyframe toggle, `DanaviewSlider` (bipolar values use `origin: 0`), value text tapping into `DanaviewNumberField`, double-tap to reset to default.
  * `InspectorNumberRow`, `InspectorToggleRow` (`DanaviewSwitchRow`), `InspectorChoiceRow` (`DanaviewSegmentedControl` / chip group), `InspectorColorRow` (swatch → `DanaviewColorPicker` sheet).
  * Rows are generated from `PropertyKey` metadata: name, unit, range, default, step, keyframable.
* **Transactions:**
  * Slider drag: `onChangeStart` → `beginTransaction(label)`, `onChanged` → `tx.update`, `onChangeEnd` → `tx.commit()`.
  * Keyboard arrow steps on a focused slider: one command per step, coalesced into one history entry when they come within 500 ms of each other.

### 9.4 Keyframe toggle (`KeyframeToggle`)

`DanaviewIconButton(size: 32)` driven by `KeyframeStateListenable(item, key, playhead)`. It notifies only when the state changes:

| State | Icon | Meaning | Tap |
|---|---|---|---|
| none | `Icons.diamond_outlined`, muted | Property is static | Add a keyframe at the playhead (from now on, the property animates) |
| animated, not at playhead | `Icons.diamond_outlined`, primaryLight | Has keyframes elsewhere | Add a keyframe at the playhead |
| at playhead | `Icons.diamond_rounded`, primaryLight | Keyframe exists at this frame | Remove it (the last remove makes the property static at its current value) |

Next to it, `‹ ›` small buttons appear when there are keyframes and jump to the previous or next keyframe (`seekExact`). The keyframes panel shows them for every property.

---

## 10. Inspector panels

Ranges and defaults are **presentation** values. The Domain doc owns the canonical ones and the UI reads them from `PropertyKey` metadata; values below are what the UI expects to see. KF = keyframable.

### 10.0 Feature placement note

The owner's list names Brightness/Contrast/Saturation/Exposure/Highlights/Shadows/Temperature/Tint under both "Video Effects" and "Color & LUT". They are implemented **once**, in the **Adjust** panel (Effects tool), to avoid two sliders for the same parameter. The **Filters** panel holds color presets, LUTs and intensity. Opacity lives in Transform, with a mirror row in Adjust › Detail that edits the same property.

### 10.1 Media panel

* **Header actions:** `Photos`/`Gallery` and `Files` buttons → `EditorEngine.pickMedia`. Results go to the media bin and, with "Add to timeline" checked (default when the timeline is empty), are inserted at the playhead on the main lane (ripple insert when ripple is on).
* **Bin:** `GridView.builder` of media cards. Each card has a thumbnail, a type glyph, duration and a "used ×N" count. Badges: Missing (error), Optimizing (proxy progress), Proxy ready.
* **Card actions:** tap = preview in place (no timeline change); "+" = add at playhead; long-press/drag = `LongPressDraggable<MediaDragData>` onto the timeline (§15.3); menu = Add as overlay, Replace selected clip, Relink…, Info, Remove from project (only when unused). Filters: All, Video, Photos, Audio. Search appears when the bin has more than 12 items.

### 10.2 Transform (video, image, text, overlay)

| Row | Control | Range (UI) | KF |
|---|---|---|---|
| Position X / Y | `DanaviewNumberField` (% of canvas, 0 = center) | −200…200 % | ✓ |
| Scale | slider + number | 1…800 % (default 100) | ✓ |
| Rotation | slider (origin 0) + number | −360…360° | ✓ |
| Flip | two toggle buttons: `Icons.flip_rounded`, and the same icon rotated 90° for vertical | — | ✗ |
| Opacity | slider | 0…100 % | ✓ |
| Fit | segmented: Fit / Fill / Stretch | — | ✗ |
| Crop | button → crop mode (§7.5) | — | ✗ |
| Reset transform | `DanaviewButton.ghost` | — | — |

Direct manipulation (§7.3) edits the same properties. The panel stays live while gesturing because both read the working project.

### 10.3 Speed (video, audio)

* `DanaviewSegmentedControl`: **Constant** | **Curve**.
* **Constant:**
  * Chips 0.25×, 0.5×, 0.75×, 1×, 1.25×, 1.5×, 2×, 3×, 4×.
  * "Custom" `DanaviewNumberField`, range 0.1–10× (Domain to confirm; clamped to `capabilities`).
* **Curve (speed ramping):**
  * Presets: Montage, Hero, Bullet, Jump cut, Flash in, Flash out, Custom.
  * `SpeedCurveEditor` (`CustomPainter`):
    * x = normalized source time 0–1; y = speed on a log scale 0.1×–10×.
    * 3–7 draggable points with linear segments (consistent with v1 linear interpolation).
    * The 1× line is drawn.
    * Point hit radius 22 on touch. Double-tap a segment adds a point; long-press a point deletes it.
    * Semantics: each point is a node with increase/decrease (speed) and left/right (time) custom actions.
* Footer: "Duration 0:12:00 → 0:06:00". "Keep audio pitch" `DanaviewSwitchRow` (default on).
* Note when the result exceeds the source: "Audio is muted above 4× on this device" (only if the engine capability says so).
* Commit label: "Change speed".

### 10.4 Audio (audio clips and video clips with audio)

| Row | Control | Range | KF |
|---|---|---|---|
| Volume | slider + number (dB readout) | 0…200 % (100 % = 0 dB) | ✓ |
| Mute | switch | — | ✗ |
| Fade in / Fade out | sliders | 0…min(10 s, duration/2) | ✗ |
| Keep pitch | switch (mirrors Speed) | — | ✗ |
| Extract audio | button (video only) | detaches to an audio lane and mutes the video's own audio, non-destructively (same media, audio stream) | — |

### 10.5 Voiceover (Audio tool › Record), shown only when `voiceRecorder != null`

* **Permission:** on first tap, an explanation sheet ("Danaview uses the microphone only while you record. Recordings stay in this project on your device.") → the OS prompt.
  * Denied: inline message with "Open Settings" (platform deep link through the engine; the UI only calls `voiceRecorder.openSystemSettings()`).
* **Record screen in the dock:**
  * Big record button (round; primary → error color while recording).
  * 3-2-1 countdown (skippable; respects reduced motion).
  * Live level meter (`DanaviewProgressBar`-style bars from `levels` at 20 Hz).
  * Elapsed time.
  * Switch "Play project while recording" (default on, project audio muted to avoid bleed).
* **Stop:** the clip is created at the record start time on the first free audio lane (a new one if needed). Label "Record voiceover". The file is project-owned.
* **Interruptions:** a phone call or route change stops the recording and keeps what was captured, with the toast "Recording stopped. 0:12 saved."

### 10.6 Adjust (Effects tool)

Three sections in a `DanaviewSegmentedControl`: **Light**, **Color**, **Detail**. Every row is KF ("basic effect keyframes") unless the Domain marks it otherwise.

| Section | Rows (range, default) |
|---|---|
| Light | Exposure (−100…100, 0), Brightness (−100…100, 0), Contrast (−100…100, 0), Highlights (−100…100, 0), Shadows (−100…100, 0) |
| Color | Saturation (−100…100, 0), Temperature (−100…100, 0), Tint (−100…100, 0) |
| Detail | Sharpness (0…100, 0), Blur (0…100, 0), Vignette (0…100, 0), Opacity (0…100, 100) |

Footer: "Apply to all clips" (the same values on every main-lane clip, one history entry) and "Reset all".
**Before/after:** press and hold the `Icons.compare_rounded` button in the header to show the original. This sends `preview.setTransient(item, adjustBypass)` while held.

### 10.7 Filters & LUT

* **Presets:** a horizontal carousel of 12 built-in looks plus "None". Each tile has a name and a small still **rendered by the engine** for the selected clip at the playhead (`thumbnails` with a `look` param; fallback: a gradient swatch). Selecting a tile applies it and shows an **Intensity** slider (0–100%, default 100, KF ✗ in v1).
* **LUTs:**
  * "Import .cube" opens `pickMedia(kinds: {lut})`. On iOS this uses the `public.data` UTI and an extension check, the same pattern as `pickSubtitleFile`.
  * The file is copied into project assets. LUTs are small, and copying makes projects self-contained.
  * Parse errors from the Domain/data parser: "This LUT couldn't be read (line 14: expected 3 numbers)." Unsupported size: "LUTs up to 65×65×65 are supported." (limit to be confirmed by the engines).
  * Imported LUTs appear in the carousel under "My LUTs", with a long-press menu offering Rename and Remove from project.

### 10.8 Text

* **Add:** a `TextItem` at the playhead (3 s, center, "Your text"). It lands on the topmost free text lane (created if needed). The panel opens on **Edit** with the keyboard up.
* **Tabs** (`DanaviewSegmentedControl`, which becomes a scrolling chip row below 360 px): **Edit · Font · Style · Background · Stroke · Shadow · Animation**.

| Tab | Controls |
|---|---|
| Edit | Multi-line `DanaviewTextField` (live preview; typing coalesces into one history entry per 1 s idle or on blur: "Edit text"), Duration `DanaviewNumberField` |
| Font | `FontPicker`: searchable list; each row renders its family name *in that font* (content preview, see §24 Q4); size slider 8–200 pt (canvas-relative) KF ✗; Bold / Italic toggles |
| Style | Color (`InspectorColorRow`), Opacity (KF ✓), Alignment (left/center/right segmented), Letter spacing (−20…100), Line spacing (0.6…3.0) |
| Background | Switch, color, opacity, padding, corner radius |
| Stroke | Switch, color, width (0…20) |
| Shadow | Switch, color, opacity, blur (0…40), distance (0…40), angle (0…360) |
| Animation | **In**: None / Fade / Slide (direction ←↑→↓) / Scale / Typewriter, plus duration (0.1…2 s). **Out**: None / Fade / Slide / Scale, plus duration. A "Preview" button loops the item's range |

* **Keyboard handling:** with the soft keyboard up, the dock pins above it. In compactPortrait under 300 px of free height, degrade step 5 hides the preview and shows a 1-line live text preview chip in the dock header instead.
* Position, rotation and scale come from direct manipulation or the Transform tool.

### 10.9 Subtitles (Captions tool; subtitle lanes)

* **Panel layout:**
  * Header actions: `Auto captions` (§12), `Add` (cue at playhead, 2 s), menu (Import SRT, Import VTT, Export SRT, Export VTT, Style, Position, Burn into video ✓, Delete track).
  * **Cue list:** `ListView.builder`; rows are `start – end` (tabular) above the text, max 3 lines with ellipsis. The current cue (under the playhead) is highlighted and auto-scrolled into view while playing.
  * Tap a row: select the cue and seek to its start.
  * **Selected row expands:**
    * `DanaviewTextField` for the text (Enter inserts a line break; Done commits).
    * Timing: start and end `DanaviewNumberField`s in timecode format with ±1 frame and ±100 ms steppers, plus a "Set start/end to playhead" button.
    * Row actions: Split at playhead (text split at the cursor position, or at the word boundary nearest the middle when the cursor isn't placed), Merge with next, Delete.
* **On the timeline:** cues are blocks on the subtitle lane. Drag moves a cue and the handles adjust start/end. Cues on one lane can't overlap; the Domain rejects overlaps or clamps the move to the nearest valid position, and the ghost shows that result.
* **Style (track-wide):** font, size, color, background box (color/opacity), outline (color/width), max lines (1–3), line width (% of canvas).
* **Position (track-wide):** Bottom / Top / Custom. Custom shows a vertical offset slider and enables dragging the caption block on the preview.
* **Import:**
  * Parsing runs in an isolate. Encoding: UTF-8/UTF-16 with BOM detection, falling back to Latin-1.
  * Result sheet: "Imported 312 captions from movie.srt", with options "New track" (default) or "Replace track".
  * Errors list the first bad line: "Line 88: the timing isn't valid".
* **Export:** the file is written to a temp folder, then the share sheet or "Save to Files" opens via the engine's `exportFile`. Options: SRT or VTT, and the track (when there are several).
* **Burn into video:** a per-track switch, also shown in the export sheet (§11.2).

### 10.10 Chroma key and Mask

| Panel | Controls |
|---|---|
| Chroma key | Enable switch. Key color: swatch, eyedropper (`Icons.colorize_rounded`, §7.5), quick chips Green and Blue. Similarity (0–100, default 40), Smoothness (0–100, 10), Spill reduction (0–100, 30). **"Show matte"** switch (`preview.setEditingMode(matte(item))`). KF ✗ in v1 |
| Mask | Shape segmented: None / Rectangle / Circle. Position X/Y, Width/Height (rectangle) or Size (circle, aspect lock toggle), Rotation, Corner radius (rectangle), Feather (0–100), Opacity (0–100), Invert switch. On-preview handles (§7.5). Position, size and opacity are KF ✓ when the Domain allows |

### 10.11 Keyframes panel

* A list of the selected item's animated properties, grouped by Transform, Adjust and Audio. Each row shows the property name, keyframe count, ‹ › jump buttons and a "Remove all" menu.
* **Selected keyframe** (picked in the list or by tapping a diamond on the timeline):
  * time (timecode with ±1 frame nudges)
  * value (`DanaviewNumberField`)
  * Interpolation: "Linear" (read-only chip; easing is out of scope for v1)
  * Delete
* **Timeline diamonds:** drag moves a keyframe (snaps to frames, the playhead and other keyframes). Long-press opens a menu with Delete and "Jump here".
* "Add/remove at playhead" uses the toggle in each property row.

### 10.12 Transitions

* **Grid of 9 tiles:**

| Tile | Glyph |
|---|---|
| None | `Icons.block_rounded` |
| Fade | `Icons.gradient_rounded` |
| Cross dissolve | `Icons.join_inner_rounded` |
| Dip to black | `Icons.contrast_rounded` |
| Dip to white | `Icons.wb_sunny_rounded` |
| Slide | `Icons.swap_horiz_rounded` |
| Wipe | `Icons.vertical_split_rounded` |
| Zoom | `Icons.zoom_in_rounded` |

  Every tile has a text label; glyphs never carry meaning alone. All glyph names above were checked against the SDK.
* Duration slider: 0.1 s up to `min(2.0 s, maxAllowed)`. `maxAllowed` comes from the Domain, based on the neighbors' handles and durations. Copy when limited: "Longer transitions need more video on both sides of the cut."
* Direction segmented control (← → ↑ ↓) for Slide and Wipe; In/Out for Zoom.
* **Preview:** when the panel opens, `preview.play(loop: cut ± (duration/2 + 0.75 s))` runs, with a "Stop preview" toggle. Leaving the panel restores the previous play state.
* "Apply to all cuts" (on the main lane; one history entry).

### 10.13 Overlay (Picture-in-Picture)

* "Add video overlay" and "Add image overlay" → `pickMedia`. The overlay goes on the topmost overlay lane free at the playhead (created if needed), scaled to 40% at center-right. It is selected and the Transform tool opens.
* Overlays use the full context-tool set (§9.2): transform, crop, opacity, chroma, mask, keyframes and speed. Their independent lanes give them **independent timeline control**.

### 10.14 Canvas / Format

* Aspect: Original (from first clip), 16:9, 9:16, 1:1, 4:5, 4:3, 21:9.
* Background: Color (picker) or Blur of the video below (if the Domain supports it; otherwise color only).
* Frame rate: 24 / 25 / 30 / 50 / 60 or "Match first clip".
* Resolution base: 720p / 1080p / 4K (capability-gated). This sets the canvas pixel size used for text sizes and positions.
* Changing the aspect shows a preview of the new letterbox and the toast "Clips keep their size; adjust them with Transform."

### 10.15 Freeze frame, reverse, replace

* **Freeze:** split at the playhead and insert a still of the current frame (default 3 s; "Duration" `DanaviewNumberField` in the confirmation sheet). The still is a project-owned asset produced by `MediaJobs.freezeFrame`. While it is generated, a placeholder item shows a spinner badge.
* **Reverse:** `MediaJobs.reverse(item)` produces a project-owned reversed rendition. The clip shows a progress badge ("Reversing 45%"), and a background-task row allows Cancel. When the rendition is ready the clip switches to it automatically. Undo restores the forward clip. Export waits for or blocks on unfinished reverse jobs: "Finish reversing 1 clip before exporting" with "Wait" or "Cancel reverse".
* **Replace:** pick media → `ReplaceMedia(item, media)`. Effects, transform and timeline range are kept. When the new media is shorter than the used range, the clip is trimmed and the toast says "The new video is shorter, so the clip was trimmed to 0:04." Kind mismatch: video can replace video or image; audio only audio.

---

## 11. Export

### 11.1 Entry and pre-checks

The Export button runs `ExportController.prepare()`. These checks run in order and **each failure has its own UI**:

1. **Missing media:** relink sheet with the headline "Relink 2 missing files to export" (§13).
2. **Pending media jobs** (reverse, freeze frame): "Finishing 1 clip…" with progress, then continues automatically; Cancel is available.
3. **Empty timeline:** toast "Add a clip before exporting."
4. **Storage:** compare the estimate (§11.3) with free space from the engine. When short: "You need about 1.2 GB free to export. Free up space or lower the resolution."
5. **Background capability notice** (first export only): see §11.5.

### 11.2 Export sheet (`showDanaviewSheet(title: 'Export')`)

```
Presets   [YouTube] [Shorts] [Reels] [IG Feed] [TikTok] [Custom]   (DanaviewChipGroup, wraps)
          1920×1080 · 30 fps · H.264 · ≈ 210 MB                     (summary, caption style)
▸ Custom settings (expands when Custom is chosen, or tap "Edit")
   Format        MP4 | MOV*               (segmented; MOV only if capabilities.movContainer)
   Codec         H.264 | H.265*           (H.265 only if capabilities.hevcEncode)
   Resolution    720p | 1080p | 1440p* | 4K*   (shows actual W×H for the project aspect)
   Frame rate    24 | 25 | 30 | 50* | 60*      (* capability by resolution)
   Quality       Smaller | Balanced | High | Maximum    (sets video bitrate)
   Video bitrate Auto (12 Mbps) [Custom slider 2–100 Mbps, clamped by capability]
   Audio         96 | 128 | 192 | 256 | 320 kbps (AAC)
Captions  ☑ Burn "Captions (Spanish)" into the video     (one row per subtitle track)
          ☐ Also save captions as  SRT | VTT
Save to   (•) Photos / Gallery   ( ) Files…   ( ) Share…
          ☐ Keep a copy in Danaview (On This Device)
[ Export ]                                                  (DanaviewButton.primary, expand)
```

* **Aspect mismatch** between the preset and the project (for example a 16:9 project with the TikTok preset): an inline notice "Your project is 16:9. TikTok videos are 9:16, so yours will have black bars." with the button "Change project to 9:16", which opens the Canvas panel. Export never silently crops.
* **"Keep a copy in Danaview"** writes the export to `Documents/Exports/`, so it shows in the existing "On This Device" library and can be played immediately. It is off by default to avoid doubling storage.
* **Preset table** (UI defaults; the Export/engine owners confirm the encoder parameters; platform guidance is non-binding hints, flagged in §24):

| Preset | Size | FPS | Codec | Video | Audio |
|---|---|---|---|---|---|
| YouTube (HD) | 1920×1080 (or project aspect at 1080p) | project, max 60 | H.264 High | 8 Mbps at ≤30 fps / 12 Mbps at 50–60 fps | AAC 192 kbps, 48 kHz |
| YouTube 4K (shown when the source and capability are ≥ 2160p) | 3840×2160 | project, max 60 | H.265 if supported, else H.264 | 35–45 Mbps (H.264) / ~60% of that with HEVC | AAC 256 kbps |
| YouTube Shorts | 1080×1920 | project, max 60 | H.264 | 8–12 Mbps | AAC 192 kbps |
| Instagram Reels | 1080×1920 | 30 | H.264 | 8 Mbps | AAC 128 kbps |
| Instagram Feed | 1080×1350 (4:5) | 30 | H.264 | 6 Mbps | AAC 128 kbps |
| TikTok | 1080×1920 | 30 (60 if the project is 60) | H.264 | 8 Mbps | AAC 128 kbps |
| Custom | any capability-supported combination | | | | |

Quality multipliers on the auto bitrate: Smaller ×0.6, Balanced ×1.0, High ×1.5, Maximum ×2.0 (capped by the encoder level).
Last-used settings are remembered per project.

### 11.3 Size estimate

`bytes ≈ (videoBps + audioBps) · durationSec / 8 · 1.02`. It is labeled "≈", rounded to 2 significant figures, and recomputed on every change.

### 11.4 Progress, cancel, completion and failure

`ExportUiState` (sealed):

| State | View |
|---|---|
| `Preparing` | Spinner, "Preparing…" |
| `Running(progress)` | Big determinate `DanaviewProgressBar` and percent; phase label (Rendering video / Mixing audio / Finishing / Saving to Photos); ETA ("About 1 min left", after ≥ 3 samples); optional small live thumbnail; **Cancel** (`DanaviewButton.secondary`) |
| `Backgrounded` | Text depends on capability: "Export continues in the background. You'll get a notification when it's done." (Android FGS / iOS continued processing) or "Export pauses while Danaview is in the background. Keep Danaview open for the fastest export." |
| `Interrupted(canResume)` | "Export was interrupted." [Resume] (if `canResume`) or [Start again] |
| `Cancelling` | Spinner, "Cancelling…" |
| `Completed(result)` | `Icons.check_circle_rounded` (success), "Saved to Photos", file size and duration, buttons **Share**, **Play** (opens the existing player), **Done** |
| `Failed(failure)` | Message from §18. Primary action from the failure kind: "Try again", "Export with H.264" (HEVC encoder failure), "Lower resolution" (encoder size limit), "Free up space". Secondary "Copy details" (failure code and settings; no media paths) |

* Cancel asks for confirmation: "Stop exporting? The partial file is deleted." Destructive "Stop export" / "Keep exporting". Cancel → `job.cancel()` → `Cancelling` → the sheet closes and the toast says "Export cancelled".
* The export sheet is non-dismissible while running (`isDismissible: false`, no drag-to-close). Editing is blocked during export: the sheet is modal. The export uses a snapshot RenderPlan, so concurrent editing would be safe for the data, but the device's encoder and GPU are saturated.
* Wakelock is held while running.

### 11.5 Background rendering (capability-driven copy and permission)

| `capabilities.backgroundKind` | UX |
|---|---|
| `foregroundService` (Android) | First export on Android 13+: explain "Allow notifications to see export progress when Danaview is in the background", then request `POST_NOTIFICATIONS` through the engine. If denied, export still works while visible. The notification has progress and Cancel (native area). |
| `continued` (iOS 26+ `BGContinuedProcessingTask`, if the iOS area adopts it) | No in-app prompt; the system shows progress. |
| `timeLimited` / `none` | The `Backgrounded` copy above. On return, the state becomes `Running` or `Interrupted`. |

### 11.6 Hardware acceleration

The export settings show the info row "Uses your device's hardware video encoder". There is no user toggle. When the engine reports `hardwareUnavailableFallback`, the summary shows "Software encoding (slower)".

---

## 12. AI subtitles (Auto captions)

### 12.1 Flow and states (`AutoCaptionsController`)

```
idle
 └─ pickLanguage ──(model ready)────────────────────────────┐
      └─(model missing/corrupt)─ consent ─ downloading ─ verifying ─┤
                                     │ failed(retry)                │
                                     ▼                              ▼
                                   idle             options ─ extracting ─ transcribing ─ segmenting ─ review ─ inserted
                                                       (range, style)          │ cancel → idle (nothing inserted)
                                                                               │ failed(kind) → retry / back
```

```dart
sealed class AutoCaptionsState {}
final class PickLanguage extends AutoCaptionsState { TranscriptionLanguage? selected; String query; }
final class ModelConsent extends AutoCaptionsState { SpeechModelSpec spec; bool onCellularHint; int freeBytes; }
final class ModelDownloading extends AutoCaptionsState { int received, total; double? bytesPerSec; }
final class ModelVerifying extends AutoCaptionsState {}
final class CaptionOptions extends AutoCaptionsState { CaptionRange range; CaptionStyle style; bool replaceGenerated; }
final class Transcribing extends AutoCaptionsState { TranscriptionPhase phase; double fraction; TimeUs processed, total; }
final class CaptionsReady extends AutoCaptionsState { int cueCount; TranscriptionLanguage language; }
final class AutoCaptionsFailed extends AutoCaptionsState { EditorFailure failure; AutoCaptionsState retryFrom; }
```

### 12.2 Screens (one `showDanaviewSheet(title: 'Auto captions')` with `DanaviewStepIndicator`)

1. **Language** (step 1):
   * `DanaviewSearchField` plus a list of `DanaviewListTile(title: englishName, subtitle: nativeName, selected:)`.
   * Recent languages at the top, the device locale's language preselected.
   * An "Auto-detect" row appears only if the AI area supports it. The owner requires a user choice, so it is not the default.
   * Primary "Continue".
2. **Model consent** (only if the model is missing or corrupt):
   * Icon `Icons.cloud_download_rounded`. Title "Download speech model".
   * Body: "Auto captions run entirely on this device. Danaview needs to download the speech recognition model once (**57 MB**, from **huggingface.co**). After that, captions work offline and your audio never leaves this device."
   * Size and host come from `SpeechModelSpec`, never hard-coded; the example values are illustrative.
   * Hint shown when the engine reports a metered connection: "This may use mobile data."
   * Free space check: "Not enough space: you need 57 MB free."
   * Buttons: **Download** (primary) and **Not now**. The `UserConsent` value is created only here (§2.4).
3. **Downloading:** `DanaviewProgressBar`, "23 of 57 MB", speed, Cancel. The sheet can be closed: the download continues while the app is foregrounded, and a background-task row shows progress. A resumed download continues from where it stopped (AI area).
4. **Options** (step 2):
   * Range: Whole video / Selected clips / From playhead to end.
   * Caption style: Sentences (up to 2 lines, 42 characters) / Short phrases (1 line, good for Shorts and Reels).
   * When a generated track exists: switch "Replace previous auto captions" (default on). Copy: "Your edits to those captions will be replaced."
   * Primary "Create captions".
5. **Transcribing** (step 3):
   * Phases with progress: "Preparing audio…", then "Transcribing 2:10 of 6:45", then "Splitting into captions…".
   * Cancel discards the result, inserts nothing, and leaves no partial track.
   * Wakelock is held. If the app is backgrounded the job pauses or fails per AI area; when the app returns, the UI shows a Resume/Restart choice.
6. **Done:** the sheet closes. A new subtitle lane "Captions (Spanish) · Auto" is inserted as **one history entry** ("Auto captions") and the Subtitles panel opens with the list. Toast "Added 84 captions" with an **Undo** action.

### 12.3 Afterwards

* Generated cues are ordinary cues and fully editable (§10.9). The lane keeps `generated: language, model, date` metadata, which drives the **Regenerate** menu item (step 1 preselects the language).
* Export as SRT/VTT and burn-in reuse §10.9 and §11.2.
* Failure copy (§18): no audio in range ("There's no audio to caption in this part of the video."), no speech found ("No speech was found. Check the language and try again."), model corrupt ("The speech model is damaged. Download it again?" → consent step with copy "Download again"), out of space, cancelled (silent).

---

## 13. Missing media, relink, recovery and migration UX

### 13.1 Detection and surfacing

* `MediaHealthController` subscribes to `MediaPoolService.watchAvailability(project)` at open, on app resume and after relinks.
* **Projects card:** badge "2 missing".
* **Editor:** `MissingMediaBanner` under the top bar (warning color icon, 1 line): "2 files are missing · Relink". It can be dismissed for this session but returns on export.
* **Timeline:** clips render offline (§8.6). **Preview:** the "Media missing" card when the playhead is on an offline clip.

### 13.2 Relink sheet (`showDanaviewSheet(title: 'Missing media')`)

* For each missing media item, a row with a type glyph, original file name, last known folder (middle-ellipsized), duration and size, and "used in 3 clips". Actions: **Locate…** (`pickMedia`, single), and a menu with Remove clips that use it / Replace with other media….
* **Validation** after the user picks a file (`checkRelink`):

| Result | UI |
|---|---|
| `match` | ✓ success color, "Relinked" |
| `durationMismatch` | Confirm "This file is 0:42 but the original was 0:45. Clips past 0:42 will be shortened. Use it anyway?" |
| `differentKind` | Error "Pick a video file to replace a video." |
| `unsupported` | Error with the compatibility reason |

* "Relink others in the same folder" (when the picked file sits next to other missing names): automatic attempt, then a report "Found 3 of 4".
* All relinks in one sheet session form **one history entry** ("Relink media"). Original files are only *referenced*, never moved or renamed.

### 13.3 Recovery

* **On the Projects screen:** the recovery banner (§5.1).
* **Opening a project that has a pending recovery** (`LoadedProject.pendingRecovery`): `DanaviewDialog(icon: Icons.history_rounded, title: 'Restore unsaved changes?', message: 'Danaview closed before your last changes to "Goa trip" were saved (changes from 14:32).', actions: [Restore (primary), Open last saved])`. Choosing "Open last saved" keeps the recovery file until the next successful save (Persistence decides). The UI copy says "You can still restore them from Projects until you save."

### 13.4 Migration

* **Opened with a migration** (`migratedFrom`): a one-time toast "Updated this project for the new version of Danaview." Persistence keeps the pre-migration backup; the UI does not expose it.
* **Newer schema:** blocked with the dialog in §5.2.
* **Corrupt project:** the card shows "Can't open" with a menu offering "Restore last good version" (if Persistence keeps one) or Delete.

---

## 14. Undo/redo, save status, clipboard

### 14.1 History behavior

* One user intent equals one entry. Transactions (§16.4) guarantee this for gestures. Text typing coalesces by 1 s idle or blur. Panel "Apply to all" counts as one entry.
* Selection changes, zoom, scroll, playhead and panel navigation are **not** in history.
* After undo/redo:
  * Selection is restored to the affected items when they still exist.
  * The playhead is not moved, but the viewport `ensureVisible`s the affected range.
  * A short toast "Undid Split clip" appears on touch only. On a keyboard the label is already in the tooltip, and the toast is suppressed after three consecutive undos.

### 14.2 History sheet

Long-press on undo (or the Project sheet › "Edit history") opens `showDanaviewSheet(title: 'Edit history')` with the last 50 labels, newest first. The current position is marked. Tapping a row undoes or redoes to that point, as one controller call that applies N steps and patches the plan once.

### 14.3 Save status and manual save

* `SaveStatus` drives the title subtitle (§6.4). ⌘/Ctrl+S and Project sheet › Save run `saveNow(manual: true)`, then the toast "Saved". Persistence may also mark this as a manual save point for recovery.
* Autosave scheduling belongs to Persistence. The UI shows the states and calls `requestAutosave()` after every commit, plus `flush()` on lifecycle events.
* A save failure shows status "Couldn't save · Retry" and **one** toast per failure streak: "Couldn't save changes: your device is full." Edits continue in memory, and the journal (Persistence) keeps them recoverable.

### 14.4 Clipboard (in-app only)

```dart
@immutable
class EditorClipboard {
  final List<ClipboardItem> items;     // serialized items + lane kind + offset from first start
  final ProjectId sourceProject;       // paste across projects is allowed; media refs are re-added to the pool
  final DateTime copiedAt;
}
```

* **Copy** (⌘C) puts the serialized selection on the clipboard. **Cut** (⌘X) copies, then deletes, as one history entry "Cut".
* **Paste** (⌘V) inserts at the playhead on the original lane kinds: the selected lane if compatible, otherwise the first free lane of each kind, created as needed. Ripple mode applies.
* **Duplicate** (⌘D) inserts right after the selection on the same lane (ripple), or on a free lane if the space is occupied.
* The system clipboard is untouched, except subtitle cue text, which is also copied as plain text for convenience.

---

## 15. Keyboard, mouse and drag-and-drop

### 15.1 Shortcuts (active whenever a hardware keyboard sends key events: iPad, Android, and desktop later)

`⌘` means Command on Apple platforms and Ctrl elsewhere. Built as `SingleActivator(key, meta: isApple, control: !isApple)`.

| Keys | Action | Notes |
|---|---|---|
| Space, K | Play / pause | |
| ← / → | Previous / next frame | hold to repeat |
| Shift + ← / → | Back / forward 1 second | |
| ↑ / ↓ | Previous / next edit point (clip boundary or marker) | |
| Home / End | Start / end of the project | |
| S | Split at playhead | §8.9 targeting |
| Delete, Backspace | Delete selection | leaves a gap unless ripple is on |
| Shift + Delete | Ripple delete | |
| ⌘Z | Undo | |
| ⌘⇧Z (and Ctrl+Y on non-Apple) | Redo | |
| ⌘S | Save | works even while a text field is focused |
| ⌘C / ⌘X / ⌘V / ⌘D | Copy / cut / paste / duplicate | |
| ⌘A | Select all (on the focused lane if any, else all) | |
| Esc | Cancel drag/gesture → close panel → clear selection → exit fullscreen | |
| M | Add marker | |
| N | Toggle snapping | |
| R | Toggle ripple editing | |
| ⌘= / ⌘− / Shift+Z | Zoom in / out / to fit | |
| F | Fullscreen preview | |
| ⌘/ or ? | Keyboard shortcuts sheet | |

### 15.2 Implementation

```dart
enum EditorActionId { playPause, prevFrame, nextFrame, back1s, forward1s, prevEdit, nextEdit, goStart, goEnd,
  split, delete, rippleDelete, undo, redo, save, copy, cut, paste, duplicate, selectAll, escape, addMarker,
  toggleSnapping, toggleRipple, zoomIn, zoomOut, zoomFit, fullscreenPreview, showShortcuts, /* + tool actions */ }

@immutable
class EditorActionSpec {
  final EditorActionId id; final String label; final IconData icon;
  final List<ShortcutActivator> shortcuts;     // empty for touch-only actions
  final bool Function(EditorState s, EditorSelection sel) isEnabled;
  final void Function(EditorActionContext ctx) invoke;
  final bool worksInTextFields;                // only save + escape
}

class EditorActionIntent extends Intent { const EditorActionIntent(this.id); final EditorActionId id; }

class _EditorAction extends ContextAction<EditorActionIntent> {
  @override bool isEnabled(EditorActionIntent i, [BuildContext? c]) => !_textFieldFocused || spec(i).worksInTextFields;
  @override bool consumesKey(EditorActionIntent i) => !_textFieldFocused || spec(i).worksInTextFields;
}
```

* `EditorShortcuts` wraps the editor in `Shortcuts(shortcuts: registry.activators)` + `Actions` + `Focus(autofocus: true)`.
* **Focus guard:** the editor's `Shortcuts` sits *below* `WidgetsApp`'s `DefaultTextEditingShortcuts`, but above any focused text field, so its bindings see Space and Backspace first. With the guard, actions report disabled and don't consume the key while an `EditableText` has focus, so the key reaches text input. Detection: `FocusManager.instance.primaryFocus?.context?.widget is EditableText` (or an ancestor check).
* After a sheet or text field closes, focus returns to the editor root node, so shortcuts resume.
* **Shortcuts sheet:** generated from the registry and grouped (Playback, Editing, Timeline, View), using `⌘`/`Ctrl` glyphs per platform. iPadOS shows no system shortcut overlay for Flutter apps, because Flutter doesn't register `UIKeyCommand`s; see §24. This sheet fills that gap.

### 15.3 Drag and drop

* **In-app (v1, all platforms):** media bin card → timeline. The bin uses `LongPressDraggable` on touch and `Draggable` on pointer devices. `TimelineDropTarget.onMove` → `interaction.updateDrop(globalPosition)` computes the lane and the snapped time and shows a drop ghost (with `dryRun(InsertMedia)`). Accept → `insertMedia`.
* **External drops:**
  * Desktop (later): reuse `desktop_drop`, as the player does.
  * iPad and Android (drag from Files/Photos): **not in v1**. Flutter has no built-in external drop on mobile, and a plugin (for example `super_drag_and_drop`) is needed. It is listed as a v1.x candidate in §24.

### 15.4 Mouse

Covered in §8.4 and §8.8: wheel and trackpad scroll and zoom, hover cursors, right-click menus, marquee, ruler click and drag, pointer-drag of selected clips. On iPad with a trackpad these work through Flutter's pointer events with no extra code.

---

## 16. State management architecture (Riverpod 2, StateNotifier)

### 16.1 Provider graph

```dart
// Roots (overridden in lib/main.dart; fakes in tests)
final editorEngineProvider          = Provider<EditorEngine>((ref) => throw UnimplementedError());
final projectRepositoryProvider     = Provider<ProjectRepository>((ref) => throw UnimplementedError());
final mediaPoolServiceProvider      = Provider<MediaPoolService>((ref) => throw UnimplementedError());
final transcriptionServiceProvider  = Provider<TranscriptionService>((ref) => throw UnimplementedError());
final editorPrefsProvider           = Provider<EditorPrefs>((ref) => throw UnimplementedError());
final editorCapabilitiesProvider    = FutureProvider<EditorCapabilities>((ref) => ref.watch(editorEngineProvider).capabilities());

// App-level
final editorLauncherProvider        = Provider<EditorLauncher>(...);
final projectsControllerProvider    = StateNotifierProvider.autoDispose<ProjectsController, ProjectsState>(...);
final editorClipboardProvider       = StateProvider<EditorClipboard?>((ref) => null);   // survives editor close
final thumbnailCacheProvider        = Provider<ThumbnailCache>(...);   // app-wide memory LRU, disposed on low memory
final waveformCacheProvider         = Provider<WaveformCache>(...);

// Per open project (family keyed by ProjectId; autoDispose with keepAlive until close() completes)
final editorSessionProvider    = Provider.autoDispose.family<EditorSession, ProjectId>(...);
final editorControllerProvider = StateNotifierProvider.autoDispose.family<EditorController, EditorState, ProjectId>(...);
final playheadProvider         = Provider.autoDispose.family<PlayheadController, ProjectId>(...);  // ChangeNotifier, not Riverpod state
final transportProvider        = Provider.autoDispose.family<TransportController, ProjectId>(...);
final viewportProvider         = Provider.autoDispose.family<TimelineViewportController, ProjectId>(...);
final interactionProvider      = Provider.autoDispose.family<TimelineInteractionController, ProjectId>(...);
final timelineSnapshotProvider = Provider.autoDispose.family<TimelineSnapshot, ProjectId>((ref, id) {
  final holder = ref.watch(_snapshotHolderProvider(id));     // plain object kept alive with the editor
  final project = ref.watch(editorControllerProvider(id).select((s) => s.project));
  return holder.last = TimelineSnapshotBuilder.build(previous: holder.last, project: project); // §16.6
});
final exportControllerProvider       = StateNotifierProvider.autoDispose.family<ExportController, ExportUiState, ProjectId>(...);
final autoCaptionsControllerProvider = StateNotifierProvider.autoDispose.family<AutoCaptionsController, AutoCaptionsState, ProjectId>(...);
final relinkControllerProvider       = StateNotifierProvider.autoDispose.family<RelinkController, RelinkState, ProjectId>(...);
```

Widgets get the id from `EditorScope.idOf(context)`, an `InheritedWidget` placed by `EditorScreen`, so ids are not threaded through constructors. A family is used instead of scoped overrides because it is explicit, needs no `dependencies:` declarations, and makes tests straightforward.

### 16.2 `EditorState`

```dart
@immutable
class EditorState {
  final EditorPhase phase;               // opening | ready | failed | closing
  final EditorFailure? failure;          // phase == failed
  final EditProject? project;            // committed project, or working copy during a transaction
  final bool inTransaction;
  final HistoryStatus history;           // canUndo, canRedo, undoLabel, redoLabel
  final SaveStatus save;                 // clean | edited | saving | saved(at) | failed(failure)
  final EditorSelection selection;
  final EditorTool? tool;                // active top-level tool
  final InspectorRoute? inspector;
  final EditModes modes;                 // ripple, snapping, multiSelect, centerPlayhead, safeGuides, laneHeight
  final PreviewStatus preview;           // starting | ready | degraded(q) | failed(f); quality; useProxies
  final MediaHealth media;               // missing ids, relinkRequired
  final List<EditorTaskInfo> tasks;      // proxies, reverse, freeze, waveform, captions, download
  const EditorState({...});
  EditorState copyWith({...});
}

@immutable
class EditorSelection {
  final Set<ItemId> items; final ItemId? primary;
  final TrackId? lane; final MarkerId? marker; final KeyframeRef? keyframe;
  final TransitionRef? transition; final GapRef? gap;
  bool get isEmpty;
  static const empty = EditorSelection();
}
```

**Not in `EditorState`**, because these values are high-frequency or local to a widget:
* playhead time (`PlayheadController`)
* play state and rate (`TransportController`: `ValueListenable<TransportState>`)
* zoom and scroll (`TimelineViewportController`)
* drag ghosts and guides (`TimelineInteractionController`)
* the manipulation gesture in progress (overlay `State`)
* panel-local UI (expanded sections, search text)

### 16.3 `EditorController` API

```dart
class EditorController extends StateNotifier<EditorState> {
  EditorController(this.id, this._session, this._ref) : super(const EditorState.opening());

  // Lifecycle
  Future<void> open({TimeUs? initialPlayhead});
  Future<CloseOutcome> close();                       // flush; never throws
  Future<SaveOutcome> saveNow({bool manual = false});
  void onAppInactive(); void onAppHidden(); void onAppResumed(); void onMemoryPressure();

  // Core mutation path
  EditResult apply(EditCommand command);              // commit + plan patch + autosave request + event
  EditTransaction beginTransaction(String label);     // only one open at a time; a new one cancels the old
  bool undo(); bool redo(); void jumpHistory(int steps);

  // Selection and navigation (not history)
  void select(ItemId id, {SelectMode mode = SelectMode.replace});  // replace | toggle | extend
  void selectAt(TrackId lane, TimeUs t);
  void selectAll({TrackId? lane});
  void selectTransition(TransitionRef r); void selectGap(GapRef g); void selectMarker(MarkerId m);
  void selectKeyframe(KeyframeRef k);
  void clearSelection();
  void setTool(EditorTool? tool);
  void openInspector(InspectorRoute route); void closeInspector();
  void setModes(EditModes Function(EditModes) update);

  // Events for one-shot UI effects (toasts, haptics, announcements)
  Stream<EditorEvent> get events;
}

sealed class EditResult {}
final class EditApplied extends EditResult { final String label; final Set<ItemId> affected; }
final class EditRejected extends EditResult { final EditRejection reason; }   // -> toast via editor_messages
```

UI intents become commands in `EditorActions`, a stateless helper that reads selection, playhead and modes. This keeps the controller small:

```dart
class EditorActions {
  EditorActions(this._c, this._playhead, this._clipboard);
  EditResult split();                                    // §8.9 targeting
  EditResult deleteSelection({required bool ripple});
  EditResult duplicate(); void copy(); EditResult cut(); EditResult paste();
  EditResult insertMedia(List<MediaId> media, {TrackId? lane, TimeUs? at, InsertMode mode = InsertMode.auto});
  EditResult replaceMedia(ItemId item, MediaId media);
  Future<EditResult> freezeFrame({Duration length = const Duration(seconds: 3)});
  Future<EditResult> reverse(ItemId item);
  EditResult extractAudio(ItemId item);
  EditResult addText(); EditResult addOverlay(MediaId media);
  EditResult addMarker({String? name});
  EditResult setLaneFlags(TrackId lane, {bool? locked, bool? hidden, bool? muted, bool? solo});
  EditResult setProperty<T>(ItemId item, PropertyKey<T> key, T value);     // keyframe-aware at playhead
  EditResult toggleKeyframe(ItemId item, PropertyKey key);
  EditResult setTransition(TransitionRef ref, TransitionSpec? spec); EditResult applyTransitionToAll(TransitionSpec spec);
  // subtitles: addCue, setCueText, setCueRange, splitCue, mergeCues, deleteCues, setSubtitleStyle,
  // importSubtitles(path, {TrackId? into, bool replace}), Future<File> exportSubtitles(TrackId, SubtitleFormat)
}
```

### 16.4 Transactions

```dart
abstract interface class EditTransaction {
  String get label;
  void update(EditCommand command);   // replaces the previous update (not cumulative); applied to the base project
  void commit();                      // one history entry; plan patch; autosave request
  void cancel();                      // restores base; clears transients
  bool get isOpen;
}
```

* `update` applies `command` to the **base project** captured at `begin`, never on top of the previous update. This keeps it idempotent: dragging back to the start yields exactly the base.
* State emission during a transaction is coalesced to once per frame (`SchedulerBinding.scheduleFrameCallback`).
* Native gets `setTransient(item, patch)` when the change is property-only. Structural changes during a transaction (a ripple drag) are *not* sent to native per frame: the ghosts show them and the preview updates on commit. This keeps platform-channel traffic bounded (§17.1).
* If the app goes inactive with a transaction open, it is cancelled (the gesture was interrupted).

### 16.5 Data flow

```
 gesture / tap / key
        │
        ▼
 EditorActions ──► EditorController.apply(cmd) ──► Domain.applyCommand (pure, main isolate, <2 ms typical)
        │                    │
        │                    ├─► state = state.copyWith(project: p', history, save: edited)  ──► selective rebuilds
        │                    │                                                     (select() on slices)
        │                    ├─► EditorSession.planSync.schedule(p')    ──► compileRenderPlan (isolate if > 300 items)
        │                    │                                              └─► diffPlans ─► preview.applyPatch
        │                    ├─► Persistence.requestAutosave(p')  (debounced by Persistence; encode in isolate)
        │                    └─► events.add(EditApplied/Rejected)  ──► toast / haptic / announcement
        ▼
 native preview renders ──► PreviewClock ──► PlayheadController ──► painters (no rebuilds)
```

**`PlanSync`** has at most one compile in flight. When edits arrive during a compile, only the latest project is compiled next, so intermediate states are skipped. Patches are applied in order. If a patch fails (the native side reports `planRejected`), `PlanSync` falls back to `setPlan(full)` and logs it.

### 16.6 Rebuild matrix (performance contract)

| Widget | Listens to | Rebuilds when |
|---|---|---|
| `EditorScaffold` | `select((s) => (s.phase, s.inspector?.runtimeType, s.tool))` + `MediaQuery` | layout-affecting changes only |
| `EditorTopBar` | `select((s) => (s.project?.name, s.save, s.history))` | name, save status, undo labels |
| `TimelineView` | `timelineSnapshotProvider(id)` + `select(selection, modes)` | committed project revision, selection, modes |
| `RenderTimelineCanvas` | viewport, cache arrivals, interaction | **repaint only** |
| `PlayheadLayer`, `TimecodeText` | `PlayheadController` | repaint / single `Text` rebuild per frame change |
| `ToolStrip` | `select((s) => (s.selection, s.tool))` + capabilities | selection or tool change |
| `InspectorHost` | `select((s) => s.inspector)` | panel change |
| Each panel | `select` on its target item's relevant properties | that item's properties change |
| `KeyframeToggle` | `KeyframeStateListenable` | keyframe state at the playhead flips |
| `ManipulationOverlay` | working project's selected-item box + playhead | repaint only |

`timelineSnapshotProvider` keeps the previous snapshot in a private `_SnapshotHolder` (its own `Provider.autoDispose.family`, alive as long as the editor), so the builder can reuse instances (§8.2) without relying on provider self-state. Tests assert rebuild counts with a `debugRebuildCounter` hook, active only in debug builds (§21.2).

---

## 17. Threading, caches and performance mechanics

### 17.1 Threads and isolates

| Work | Where | Notes |
|---|---|---|
| Widgets, gestures, painting, domain commands, `dryRun` | Main (UI) isolate | Commands must be pure and fast (§22 budgets). |
| RenderPlan compile + diff (projects > 300 items) | `Isolate.run` worker (or a long-lived worker isolate in `EditorSession`) | Below the threshold, compiling on the main isolate is cheaper than copying. |
| Project JSON encode/decode, autosave | Worker isolate (Persistence) | UI never awaits encode on the main isolate. |
| SRT/VTT parse/serialize, `.cube` parse | `Isolate.run` | Files can be MBs. |
| Waveform mip pyramid | `Isolate.run` on first load per media; result cached on disk | §17.4. |
| Image decode (thumbnail JPEG strips) | Engine IO thread via `ui.instantiateImageCodec` (async; does not block the UI isolate) | `targetWidth` set to the frame cell size. |
| Native render, decode, encode, transcription, extraction | Native threads (iOS/Android/AI areas) | Channel replies are async; events are throttled natively. |

**Platform-channel traffic budget:**
* `PreviewClock` ≤ 30 Hz (4 Hz is enough with extrapolation).
* `setTransient` ≤ 60 Hz with native coalescing.
* `seek` ≤ 1 in flight.
* Thumbnail tiles: batched, ≤ 8 in flight.
* Export, download and transcription progress ≤ 4 Hz.

### 17.2 Timeline tile cache (avoids per-frame re-recording)

`RenderTimelineCanvas` records lane content into `ui.Picture` tiles: 1024 logical px wide, per `(laneId, tileIndex)`. The cache key is `(lane.revision, zoomBucket, laneHeight, selectionHash for that lane, cacheGeneration)`.
* **Paint** adds the visible tiles' `PictureLayer`s inside an `OffsetLayer` translated by the current scroll. Only missing or stale tiles are re-recorded.
* **Scroll and playback-follow** therefore cost only layer offsets on the UI thread. The raster thread still draws the display lists each frame, which is cheap with Impeller (rects, images, lines).
* **Zoom** (continuous pinch): tiles are re-recorded at bucketed zoom levels (×1.15 steps); between buckets a tile is scaled horizontally via its transform. Exact re-record happens at gesture end.
* **Invalidation:** a lane revision change invalidates only that lane's tiles. A thumbnail or waveform arrival invalidates only the tiles whose time range overlaps it.
* Tile count is capped (visible + 1 tile each side); everything else is evicted.

This is optimization ticket **UX-44b**. Implement direct painting first (UX-16), measure against §22, and ship tiles only if the budget requires them. The interface is designed so tiles can be added without changing callers.

### 17.3 Thumbnails (client side)

* **Native produces JPEG strips:** N frames per tile at a fixed height (`laneHeight·dpr`, bucketed to 48/64/96 px) and a fixed interval chosen from the zoom: interval ladder 0.5, 1, 2, 5, 10, 30, 60 s; the cell width ≈ the lane's thumbnail width. The disk cache lives in the cache dir (engine area) keyed by `(mediaFingerprint, interval, heightPx, tileIndex, proxy)`.
* **`ThumbnailCache` (Dart):**
  * Memory LRU of decoded `ui.Image`s by byte size: budget 48 MB on `lowMemoryDevice`, 96 MB otherwise, 25% after memory pressure.
  * Request queue with priorities: `visible > overscan > prefetch(next viewport in scroll direction)`.
  * During a fast fling (|velocity| > 2000 px/s), new requests are deferred until velocity drops or the scroll ends.
  * When a tile scrolls out of the overscan, its pending requests are cancelled through `ThumbnailHandle.cancel()`.
  * Hit = drawn in the same frame. Miss = flat placeholder cell. On arrival, only the intersecting tiles are invalidated.
* **Images and freeze frames:** a single still is decoded once at lane height and repeated across the clip.

### 17.4 Waveforms (client side)

* Native returns `WaveformPeaks` (int8 min/max pairs at 200 pairs/s per media audio stream, disk-cached).
* Dart builds a mip pyramid (÷2 per level) in `Isolate.run` and keeps it in `WaveformCache` (memory LRU 24 MB; levels are `Int8List`s).
* The painter picks the level whose pairs-per-px is closest to 1 and draws vertical lines with one `drawRawPoints(PointMode.lines, Float32List)` per visible clip segment.
* A clip's speed is applied by mapping clip time → source time; reversed clips read the pyramid backward.
* Volume keyframes scale the drawn amplitude (envelope), with a thin line showing the volume curve when the clip is selected.

### 17.5 Text/paragraph cache

`ParagraphCache`: LRU of 512 `ui.Paragraph`s keyed by `(text, style id, widthBucket)`. Cleared on text-scale change and memory pressure.

### 17.6 Large projects

The design target is 2,000 items, 32 lanes, a 3-hour timeline and 300 media files:
* Timeline painting is bounded by what is visible.
* The snapshot builder reuses instances.
* The `SnapIndex` is built once per drag: O(n log n), about 1 ms at 2,000 items.
* The subtitle list and media bin are virtualized.
* The keyframe union per item is precomputed in the snapshot.
* RenderPlan compiles move off the main isolate above 300 items.
* The auto-captions list handles 3,000+ cues with `ListView.builder`.

### 17.7 Proxy media (UX side)

* Setting: Auto / Always / Off.
* Proxy jobs show as background tasks ("Optimizing 2 videos for editing · 45%") in a top-bar task indicator: a `DanaviewSpinner` with a count badge that opens `TasksSheet`.
* The media bin shows proxy badges. The preview uses proxies when quality ≠ Full or the toggle is on.
* Export always uses originals. The export sheet states this in its footer: "Exports use your original media."

---

## 18. Error handling and user messages

```dart
sealed class EditorFailure { String get code; }       // code: stable id for "Copy details"
final class ProjectNotFound extends EditorFailure {}
final class ProjectNeedsNewerApp extends EditorFailure { int schema; }
final class ProjectCorrupt extends EditorFailure {}
final class SaveFailed extends EditorFailure { SaveFailureKind kind; }     // diskFull | io | permission
final class MediaUnavailable extends EditorFailure { MediaId media; }
final class MediaUnsupported extends EditorFailure { String reason; }      // from EditCompatibility
final class ImportFailed extends EditorFailure { String fileName; ImportFailureKind kind; }
final class PreviewFailed extends EditorFailure { bool recoverable; }
final class ExportFailed extends EditorFailure { ExportFailureKind kind; } // encoderUnavailable, encoderSizeLimit, diskFull, interrupted, destinationDenied, unknown
final class PermissionDenied extends EditorFailure { AppPermission permission; } // microphone, photosAdd, notifications
final class ParseFailed extends EditorFailure { ParseFormat format; int? line; String detail; } // srt, vtt, cube
final class ModelDownloadFailed extends EditorFailure { ModelFailureKind kind; } // network, checksum, storage, cancelled
final class TranscriptionFailed extends EditorFailure { TranscriptionFailureKind kind; } // noAudio, noSpeech, modelCorrupt, cancelled, interrupted
final class UnknownFailure extends EditorFailure { Object error; }
```

**Rules:**
1. Engines and repositories convert platform exceptions into `EditorFailure` at their boundary. Controllers catch anything else and wrap it as `UnknownFailure`. **No editor action can crash the app.** `FlutterError.onError` stays the app's default.
2. `editorFailureMessage(EditorFailure)` and `editRejectionMessage(EditRejection)` live in `editor_messages.dart` and are unit-tested for every subtype. The style follows `playerErrorMessage`: plain, specific, with a next step.
3. Logging uses `debugPrint` only. There is no telemetry, consistent with the privacy policy. "Copy details" copies the code and settings, never file paths or content.
4. Rejections are informational toasts (`DanaviewToastKind.info`), not errors.

Sample copy:

| Case | Message |
|---|---|
| `EditRejected(TrackLocked)` | "This track is locked." + action "Unlock" |
| `EditRejected(NothingAtPlayhead)` (split) | "Move the playhead over a clip to split it." |
| `EditRejected(BelowMinDuration)` | "Clips can't be shorter than one frame." |
| `SaveFailed(diskFull)` | "Couldn't save changes: your device is full. Your changes are kept until you free up space." |
| `ExportFailed(encoderUnavailable)` with HEVC | "This device couldn't encode H.265 right now." + "Export with H.264" |
| `PermissionDenied(microphone)` | "Microphone access is off. Turn it on in Settings to record a voiceover." + "Open Settings" |
| `ImportFailed(unsupported)` | ""clip.mkv" can't be edited on this device. MP4, MOV and M4V videos work best." |
| `ModelDownloadFailed(network)` | "The download stopped. Check your connection and try again. Downloaded data is kept." |

---

## 19. Accessibility and no-overflow guarantees

### 19.1 Accessibility

| Surface | Semantics |
|---|---|
| Timeline container | `Semantics(label: 'Timeline', onScrollLeft/Right/Up/Down: viewport steps)`; increase/decrease = zoom |
| Each visible item (from `assembleSemanticsNode`) | Node label example: "Video clip 2 of 5, beach.mp4, starts 0:05, length 0:07, speed 2x, has effects, selected". `onTap` = select. `customSemanticsActions`: Split at playhead, Delete, Ripple delete, Duplicate, Move earlier 1 second, Move later 1 second, Move earlier 1 frame, Move later 1 frame, Trim start in 1 frame, Trim end out 1 frame, Open settings (inspector). Every gesture has a non-gesture alternative (WCAG 2.5.1 / 2.5.7) |
| Playhead | Adjustable slider: value "0:12 and 15 frames of 1:30", increase/decrease = ±1 s, plus custom actions ±1 frame |
| Track headers | Real buttons with `toggled:` for lock/visibility/mute/solo; label "Main video track, locked" |
| Markers, transitions, keyframes | Nodes with labels ("Marker Intro at 0:04", "Cross dissolve transition, 0.5 seconds", "Opacity keyframe at 0:03") and actions (select, delete, jump) |
| Preview manipulation | The overlay exposes the selected item as a node "Text 'Hello', position 50 percent, 80 percent" with custom actions Move left/right/up/down (1%), Bigger/Smaller (5%), Rotate ±5°, Reset. The numeric Transform panel offers the same control |
| Pinch-zoom | Alternatives: zoom buttons in the transport / more menu, the ⌘=/⌘− keys, and semantics increase/decrease |
| Long-press menus | Alternatives: the context tool strip, plus the custom actions above |
| Live announcements | `SemanticsService.announce` (throttled ≤ 1/s) for drag results ("Moved to 0:12"), snaps ("Snapped to marker Intro"), export completion, undo/redo labels |
| Timecode | Text with `semanticsLabel` in words ("12 seconds 15 frames of 1 minute 30 seconds") |

* **Contrast:** clip labels sit on the `overlayDark` chip. Every foreground on colored fills uses `DanaviewColors.foregroundOn(fill)`, and a test (§21.2) asserts ≥ 4.5:1 for every token pair used.
* **Targets:** at least 44×44 on touch everywhere (`DanaviewIconButton` already enforces it; timeline handles and "+" buttons have extended hit areas). Verified with `androidTapTargetGuideline` / `iOSTapTargetGuideline` / `labeledTapTargetGuideline`.
* **Reduced motion** (`MediaQuery.disableAnimationsOf`): no countdown animation, panel transitions are instant, no auto-scroll easing. Preview playback is unaffected.
* **Haptics** (snap, split, lift, keyframe add) are never the only feedback.
* **RTL:** chrome mirrors via `Directionality`. The **time axis stays left→right**, as is standard practice for timelines; headers stay on the start side.

### 19.2 No-overflow guarantees

1. **Pure layout planner** (`EditorLayoutSpec.resolve`, `PriorityRowPlanner`, tile-width and lane-height formulas) has unit tests over the full matrix, asserting `sum(regions) ≤ available` and minimums honored (or the documented degrade step applied).
2. **Widget matrix tests** for every editor surface and state (table below). Each run asserts:
   * `tester.takeException()` is null (`RenderFlex` overflows throw in tests);
   * key widgets lie inside the safe rect (`expectInside`);
   * every `RenderParagraph` that must not truncate fits (`fitsFully`, as in `text_fit_test.dart`).
3. **Long-content fixtures:** a 120-character project name; 80-character file names; a long language name ("Haitian Creole · Kreyòl ayisyen"); 3-line subtitle text; 4-hour durations (wider timecodes); 32 lanes.
4. **CI** fails on any new overflow. There are no golden-only checks for overflow.

**Matrix** (sizes are logical px; heights pair with each width):

| Dimension | Values |
|---|---|
| Width × height | 280×500, 320×568, 360×740, 390×844, 412×915 (portrait); 568×320, 667×375, 844×390, 932×430 (landscape phones); 744×1133, 834×1194 (tablet portrait); 1133×744, 1194×834, 1280×800 (tablet landscape / desktop later) |
| Text scale | 0.85, 1.0, 1.35 |
| Platform | iOS (touch), Android (touch), macOS (pointer + keyboard, for later desktop and iPad-with-trackpad parity) |
| Keyboard inset | none; 40% of height (text editing, rename prompt, timecode entry) |
| States | Projects (empty, 1, 40 projects, recovery banner, unsupported device); editor idle; clip selected (each kind); multi-select; each inspector panel (default and expanded dock); text editing with keyboard; crop / mask / eyedropper modes; fullscreen preview; export (configure, custom expanded, running, completed, failed); auto captions (each step); relink sheet; history sheet; tasks sheet; shortcuts sheet; track menu; marker sheet |

Run time is controlled by tagging: the full matrix runs nightly (`--tags overflow-full`). PRs run a 6-surface subset, always including 280×500 @1.35 and 568×320 @1.35.

---

## 20. Privacy policy, terms and platform declarations

All edits go in `packages/danaview_features/lib/src/more/legal_texts.dart`. `legalEffectiveDate` is updated to the release date. `<MODEL_HOST>`, `<MODEL_HOST_OPERATOR>` and `<MODEL_SIZE>` are filled from the AI area's final manifest. A test asserts the policy contains the exact host string used by `SpeechModelSpec.host`, so the two can't drift.

### 20.1 Privacy Policy changes

**Summary** (replace):
> Danaview keeps everything on your device. There are no accounts, no analytics, no ads and no tracking, and nothing you watch, edit or type is sent to us. The only download you don't start by opening a link is the speech model for Auto captions, and only after you agree.

**"What Danaview stores on your device"**, adding bullets:
* `LegalBullet('Video editing projects: your edits and the files the editor makes for them, such as voice recordings, freeze frames, reversed clips, optimized copies for smoother editing, thumbnails and audio waveforms. Projects refer to your original videos, photos and music where they are. Editing never changes, moves, renames or deletes your originals.')`
* `LegalBullet('On iPhone and iPad, videos and photos you add to a project from your photo library are copied into Danaview\'s own storage so the project keeps working. Deleting the project removes these copies.')` *(Exact wording depends on the Persistence area's iOS decision; on Android, items are referenced, not copied.)*
* `LegalBullet('The Auto captions speech model, once you download it.')`

**"When Danaview uses the internet"**, adding a bullet:
* `LegalBullet(lead: 'Auto captions model', 'The first time you use Auto captions, and only after you agree, Danaview downloads a speech recognition model (about <MODEL_SIZE>) from <MODEL_HOST>, a service run by <MODEL_HOST_OPERATOR>. Only the model file is requested. No audio, video, captions, text or personal data is sent. Like any website, the server sees the usual details of the connection, such as your IP address. After the download, captions are created entirely on your device and work offline.')`

and changing the closing paragraph to:
> Files on your device that you play, edit, inspect, export or browse are processed on your device and are never uploaded.

**"Files and permissions"**, replacing it with paragraph + bullets:
* `LegalBlock.paragraph('Danaview reads only the files and folders you choose to open, add to your library or add to a project, and on phones and tablets the videos you place in its own folder. It doesn\'t scan the rest of your storage, and it never changes, moves or deletes your videos, photos or music.')`
* `LegalBullet(lead: 'Photo library', 'When you add photos or videos to a project, Danaview receives only the items you pick. When you save an export to Photos or your gallery, Danaview adds that video and doesn\'t read the rest of your library.')`
* `LegalBullet(lead: 'Microphone', 'Used only while you record a voiceover in the editor. Recordings stay in that project on your device.')`
* `LegalBullet(lead: 'Notifications (Android)', 'Used only to show export progress while Danaview is in the background, if you allow it.')`

**"Your choices"**, adding bullets:
* `LegalBullet('Delete video editing projects in the editor\'s Projects screen. This removes the project and the files made for it, never your originals.')`
* `LegalBullet('Delete the Auto captions speech model, and clear editor thumbnails, waveforms and optimized copies, in Settings › Storage & history.')`

### 20.2 Terms of Use changes

* **"Your content"**, adding a paragraph: "This includes media you edit and the videos, captions and other content you create and export with Danaview. You are responsible for having the rights to the footage, music, images and fonts you use, and to publish what you create."
* **New section "Editing and exports":** "Danaview edits non-destructively and never changes your original files. Keep backups of projects and media that matter to you. Export presets for services such as YouTube, Instagram and TikTok are provided for convenience; Danaview isn't affiliated with or endorsed by those services, and their requirements can change."
* **New section "Auto captions":** "Captions are generated on your device by a speech recognition model and may contain mistakes. Review them before you publish. The model and the speech recognition engine are third-party open-source software provided under their own licenses (see Settings › About › Open-source licenses)."
* **"Trademarks"**, adding: "YouTube, Instagram and TikTok are trademarks of their respective owners."
* **"No warranty"**, extending the tool sentence: "…such as speed test measurements, data usage estimates, export file size estimates and automatic captions, are approximate."

### 20.3 Platform declarations (joint with the iOS/Android areas)

| Platform | Item | Value / note |
|---|---|---|
| iOS Info.plist | `NSMicrophoneUsageDescription` | "Danaview uses the microphone only while you record a voiceover in the video editor." |
| iOS Info.plist | `NSPhotoLibraryAddUsageDescription` | "Danaview saves the videos you export to your photo library." |
| iOS Info.plist | `NSPhotoLibraryUsageDescription` | **Only if** the Persistence area references `PHAsset`s instead of copying. Not needed with `PHPickerViewController` + copy |
| iOS | `PrivacyInfo.xcprivacy` (Runner) | Required-reason API declarations for the app's own native editor code (e.g. disk space checks before export, file timestamps); none exists in Runner today. iOS area |
| iOS | `BGTaskSchedulerPermittedIdentifiers` | Only if `BGContinuedProcessingTask` is adopted (iOS area) |
| Android | `RECORD_AUDIO` | voiceover |
| Android | `POST_NOTIFICATIONS` | export progress notification (requested in context, §11.5) |
| Android | FGS type + permission | e.g. `FOREGROUND_SERVICE_MEDIA_PROCESSING` (API 35+) / fallback type for API 34 (Android area) |
| Android | `WRITE_EXTERNAL_STORAGE` `maxSdkVersion="28"` | saving exports to the gallery on Android 9 and below |
| Android | **No** `READ_MEDIA_IMAGES` | use the Photo Picker. Google Play's photo/video permission policy discourages broad media permissions; the existing `READ_MEDIA_VIDEO` is the player's and must keep its policy justification |
| Both stores | Privacy labels / Data safety | Still "No data collected". The developer receives nothing; the model host sees an IP address like any download. Update descriptions and screenshots via fastlane metadata (ticket UX-47) |
| App | Open-source licenses page | New custom `DanaviewLicensesScreen` (no Material `LicensePage`) listing `LicenseRegistry` entries plus manual entries: whisper.cpp (MIT), Whisper model (MIT), AndroidX Media3 (Apache-2.0), bundled editor fonts (OFL-1.1), Figtree (OFL-1.1, already shipped in `fonts/OFL.txt`) |

---

## 21. Testing strategy

### 21.1 Unit tests (pure Dart, `packages/danaview_editor/test/unit/`)

| Subject | Cases |
|---|---|
| `EditorLayoutSpec.resolve` | full matrix (§19.2); kind boundaries (519/520 height, 599/600 and 999/1000 widths); degrade ladder ordering; keyboard step 5 |
| `PriorityRowPlanner` | mandatory items always placed; priority order; "more" appears iff something is hidden; measured widths at 0.85/1.35 |
| `TimelineViewportController` | `xOf`/`timeAt` round-trip; zoom anchor invariance (time under anchor fixed within 0.5 px); clamps; center-locked bounds; fling simulation ends inside bounds |
| Ruler ladder | spacing ≥ label width + 24 at all zooms; frame-level labels; 4 h durations |
| `SnapIndex` | nearest-edge selection; both edges; exclusion of dragged items; threshold conversion at zoom extremes |
| `PlayheadController` | extrapolation; ±1-frame snap rule; stale `seq` ignored; scrub coalescing (only latest pending sent; ≤ 1 in flight); `endScrub` adopts `displayedFrameTime`; notifications only on frame change |
| `EditTransaction` | idempotent update against the base; commit = 1 history entry; cancel restores; nested begin cancels the previous; app-inactive cancel |
| `TimelineSnapshotBuilder` | identity reuse for unchanged lanes/items; per-lane revision bumps |
| `Timecode` | format/parse (`1:23`, `1:23:12`, `83.5s`, `+2s`, `-10f`), 23.976/29.97/59.94 rational rates, hours |
| `EditorActions` | split targeting rules; delete vs ripple; paste lane resolution; duplicate placement |
| `editor_messages` | a message for every `EditorFailure`/`EditRejection` subtype (exhaustive switch) |
| Export estimate & presets | capability filtering (no HEVC → hidden; MOV hidden on Android); size estimate math |
| `AutoCaptionsController` | state machine transitions incl. cancel at every step; consent token required; regenerate path |
| Legal texts | policy mentions `SpeechModelSpec.host`; effective date updated |
| Dependency rule | `danaview_features/pubspec.yaml` does not list `danaview_editor` |

### 21.2 Widget tests (`test/widget/`) with `FakeEditorEngine`, `FakeProjectRepository`, `FakeTranscriptionService`

* **Fakes:**
  * `FakeEditorEngine` has a deterministic clock (`emitClock(t, playing)`), records calls (`seeks`, `transients`, `patches`), controllable failures, and fake thumbnail tiles (solid-color images).
  * `FakeProjectRepository` is in-memory with failure injection.
  * `FakeTranscriptionService` scripts progress.
* **Flows:**
  * Home: the edit button sits left of settings and opens Projects; hidden on desktop platforms.
  * Player: the Edit action hides for remote media; the unsupported-format dialog; the push to the editor with `?t=`; return restores the orientation owner (mock `SystemChrome` channel).
  * Projects: create/rename/duplicate/delete with undo; recovery banner; newer-schema dialog.
  * Editor: tap-select, long-press lift-and-drag (`tester.timedDragFrom`), trim handle drag with snapping guide, pinch zoom (two `TestGesture`s), center-locked scroll scrubs and pauses, split with the S key and the tool, delete/ripple delete, multi-select mode, marquee (mouse `PointerDeviceKind.mouse`), right-click menu, auto-scroll during an edge drag.
  * Preview: one-finger move with snap guides; pinch/rotate; corner handle; rotate handle; transient count ≤ frames; one history entry per gesture.
  * Inspectors: slider drag = one entry; the keyframe toggle cycles its three states as the playhead moves; text editing with the keyboard inset (degrade step 5).
  * Export sheet: capability gating; aspect-mismatch notice; progress → cancel confirm → cancelled; failure → H.264 fallback.
  * Auto captions: every step, cancel at each, consent-required.
  * Relink: match / mismatch / unsupported.
  * Shortcuts: each binding invokes its action; the focus guard (typing Space in a text field inserts a space and does not toggle playback; ⌘S still saves); `isApple` modifier mapping.
  * **Rebuild budget:** with 300 fake items, emit 120 clock samples while "playing" and assert that `EditorScaffold`, `TimelineView` and `ToolStrip` build counts don't change and `TimecodeText` builds ≤ number of frame changes.
  * **Accessibility:** `meetsGuideline(androidTapTargetGuideline)`, `iOSTapTargetGuideline`, `labeledTapTargetGuideline`, `textContrastGuideline` on idle, selected and inspector states; semantics custom actions on clips perform the right commands.
* **Overflow matrix:** §19.2.

### 21.3 Golden tests (`test/golden/`, Ahem test font, rendered at DPR 1 and 3)

* The timeline at four zoom levels with all item kinds, badges, selection, locked/hidden lanes, offline clips, transitions, markers and keyframes.
* The ruler at frame and minute scales.
* The manipulation overlay handles.
* The speed-curve editor.

Goldens guard *visual* regressions only; they are never the overflow check.

### 21.4 Native contract tests (owned by the engine areas, listed for traceability)

* Plan application parity: preview frame at t vs export frame at t, SSIM ≥ 0.98.
* Exact-seek frame accuracy: a frame-number-burned test clip (each frame shows its index) at random times returns the expected index.
* Thumbnails, cancel semantics, waveform peaks.
* Export codecs and containers per capability.

### 21.5 On-device integration tests (`packages/danaview_editor/integration_test/`, `integration_test` package)

Run on: iOS Simulator (latest) plus a physical iPhone (A13-class); an Android emulator (API 35) plus a physical low-tier Android (4 GB RAM) and a Pixel-class device.

1. **Player → Edit:** open the bundled `frame_counter_1080p30.mp4` test asset in the player, seek to 0:05:10, tap Edit. Assert: editor open; playhead == 5 s + 10 frames; the burned-in frame number read via `PreviewSession` debug `captureFrameHash` matches.
2. **Basic edit:** split, trim, move with snap, undo/redo, add text, add a marker, change speed to 2×, add a cross-dissolve.
3. **Export:** 720p H.264 MP4 → verify with `MediaInspector` (container mp4, video `avc1`, 1280×720, duration within ±1 frame of the timeline, AAC audio present). On capable devices, repeat with H.265 (`hvc1`).
4. **Auto captions:** with the *tiny* model pushed into the test app's models dir (no network in CI), transcribe the bundled 10 s speech clip. Assert ≥ 1 cue, cues inside the range, SRT export parses back.
5. **Recovery:** start an edit, kill the app process via the test driver, relaunch. Assert the recovery banner and that restore reproduces the edit.
6. **Missing media:** rename the test file in the *test sandbox copy*, never a user file. Assert the banner, relink the file, export succeeds.
7. **Lifecycle:** background during playback and resume; the preview refreshes (no black frame after 1 s).

### 21.6 Performance tests (profile mode)

`flutter drive --profile` with `IntegrationTestWidgetsFlutterBinding.traceAction` → `TimelineSummary`. Scripted scenarios on a generated 1,000-item / 20-lane project: 10 s of fling scrolls, 10 s of pinch zoom, 30 s of playback with center-follow, 20 drag-and-snap moves, and opening every inspector. Assertions use the §22 budgets; CI on the physical low-tier Android runs nightly. Memory is checked with `vm_service` heap snapshots at the end (Dart heap) and the `ThumbnailCache.bytes` gauge.

---

## 22. Performance budgets

Baselines: **low tier** = a 4 GB RAM Android (Snapdragon 6-series/Helio G-class) and iPhone SE (2nd gen); **mid tier** = Pixel 7a and iPhone 12. Figures are p90 unless stated otherwise.

| Metric | Low tier | Mid tier | Measured by |
|---|---|---|---|
| Editor open → first preview frame (200 items) | ≤ 2.5 s | ≤ 1.5 s | integration timer |
| Projects screen first paint (40 projects) | ≤ 400 ms | ≤ 250 ms | integration timer |
| Timeline fling/pinch: UI thread per frame | ≤ 8 ms (p99 ≤ 14) | ≤ 5 ms (p99 ≤ 10) | `TimelineSummary` build |
| Timeline fling/pinch: raster per frame | ≤ 10 ms | ≤ 7 ms | `TimelineSummary` raster |
| Playback with center-follow: UI thread per frame | ≤ 3 ms; **0 widget rebuilds** except `TimecodeText` | same | rebuild counter + summary |
| Missed frames over 30 s scripted interaction | ≤ 1% | ≤ 0.5% | summary |
| Pointer-move handling during drag (snap + `dryRun`) | ≤ 2 ms | ≤ 1 ms | `Timeline.timeSync` spans |
| Commit → preview reflects property edit | ≤ 150 ms | ≤ 80 ms | engine debug event |
| Commit → preview reflects structural edit (split/move) | ≤ 400 ms | ≤ 250 ms | engine debug event |
| Slider transient → preview | ≤ 3 frames | ≤ 2 frames | engine debug event |
| Scrub: displayed frame lag while dragging | ≤ 200 ms | ≤ 120 ms | engine debug event |
| Scrub: exact frame after release | ≤ 300 ms | ≤ 200 ms | `SeekAck` |
| Thumbnail first tile after scroll stop (cache miss) | ≤ 400 ms | ≤ 250 ms | cache instrumentation |
| Dart heap with a 1,000-item project open | ≤ 180 MB | ≤ 150 MB | heap snapshot |
| Thumbnail image memory | ≤ 48 MB | ≤ 96 MB | cache gauge |
| Main-isolate block from autosave | ≤ 2 ms | ≤ 1 ms | span around save request |

If a budget fails, the order of remedies is: tile cache (UX-44b), then lowering overscan, then fling-deferred requests, then lane-height buckets, then the proxy default.

---

## 23. Implementation tickets (this area)

Cross-area dependency tags are written as `DOM:` (domain/model), `PER:` (persistence & media), `ENG:` (Dart engine interface and fake), `IOS:`, `AND:`, `AI:`. The UI is built against **fakes first**, so M0–M1 don't wait on native code. Milestones are internal; everything ships together.

**Milestone M0: scaffold and integration**

| ID | Title | Files owned | Depends on | Acceptance criteria |
|---|---|---|---|---|
| UX-01 | Package scaffold, availability gate, root providers | `packages/danaview_editor/{pubspec.yaml, lib/danaview_editor.dart, lib/src/app/editor_availability.dart, editor_providers.dart, editor_strings.dart}`; `lib/main.dart` overrides | ENG:api+fake (interfaces only) | Package builds and analyzes clean. `EditorAvailability.platform` is supported on iOS/Android and comingSoon on desktop. The pubspec dependency-rule test passes |
| UX-02 | Orientation owner stack | `danaview_features/.../danaview_player_actions.dart` (+ `screen_orientation_policy.dart`) | — | Existing player orientation tests pass unchanged. New tests: editor over player → pop restores player mode; release of a non-top owner keeps the top |
| UX-03 | Home edit button + routes + Projects shell | `danaview_home_screen.dart`, `lib/router/app_router.dart`, `danaview_features/lib/chrome.dart`, `projects/projects_screen.dart` (shell) | UX-01 | Button sits immediately left of the gear (same size and variant). Tooltip "Video editor". Hidden on desktop; `/projects` and `/editor/x` redirect to `/` on desktop. Home overflow test at 280 px @1.35 passes |
| UX-04 | UI kit additions | `danaview_ui_kit/lib/src/components/{danaview_progress_bar, danaview_number_field, danaview_color_picker, danaview_docked_panel, danaview_search_field, danaview_step_indicator}.dart` + tests | — | Each component passes the kit's surface matrix with no overflow and has keyboard, focus and semantics tests. No Material widgets used for visuals. Exported from `danaview_ui_kit.dart` |
| UX-05 | Storage contributors + editor settings screen | `danaview_features/.../storage_usage.dart`, `danaview_storage_screen.dart`, `danaview_settings_screen.dart`, `settings_destination.dart`; `danaview_editor/.../editor_storage_contributor.dart`, `settings/editor_settings_screen.dart` | UX-01, PER:repo (sizes), AI:service (model size) | Storage shows Editor projects / Editor cache / Speech model with correct clear semantics. "Clear cache" never touches projects. Settings › Video editor is shown only when available |

**Milestone M1: projects, editor shell, timeline and core edits (on fakes)**

| ID | Title | Files owned | Depends on | Acceptance criteria |
|---|---|---|---|---|
| UX-06 | Projects screen + controller | `projects/*` | UX-03, PER:repo (or fake) | Grid and list layouts by width; create/open/rename/duplicate/delete (undo window); sort and search; empty, error and unsupported states; badges; matrix tests pass |
| UX-07 | New project sheet + import sheet | `projects/new_project_sheet.dart`, `flows/import_media_sheet.dart` | UX-06, ENG:picker, PER:mediapool | Photos/Gallery and Files pickers; per-item progress and inline errors; aspect choice; "Start empty". The copy hint appears only on iOS Photos |
| UX-08 | Editor shell + layout planner + splitter + top bar | `editor/editor_screen.dart`, `editor_scope.dart`, `layout/*` | UX-01, UX-04 | `EditorLayoutSpec` unit matrix passes (kinds, minimums, degrade ladder). Four layouts render with placeholder regions. Splitter persists per kind. PopScope back order (§4.7). Unknown project id → empty state |
| UX-09 | EditorController core + session + transactions + events | `editor/state/{editor_state, editor_controller, edit_transaction, editor_session, editor_events}.dart`, `app/editor_messages.dart` | DOM:commands+history (or fake), PER:repo | `apply`/undo/redo/transactions per §16.3–16.4. Plan sync coalescing. Autosave requested on commit; flush on hide and close. One history entry per transaction. Messages exist for every failure and rejection |
| UX-10 | Timeline viewport + ruler | `timeline/{timeline_viewport, ruler, timeline_metrics, timeline_style}.dart` | UX-08 | Zoom-anchor invariance, bounds, center-locked and free modes, fling (unit tests); ladder spacing tests; ruler golden |
| UX-11 | Timeline snapshot + canvas painting + hit testing | `timeline/{timeline_snapshot, render_timeline_canvas, timeline_hit, playhead_layer}.dart`, `caches/paragraph_cache.dart` | UX-09, UX-10, DOM:model | Identity reuse tests. Paints only the visible window (instrumented count). All §8.6 visuals (golden). `hitTestTimeline` correct for every hit type (unit tests). Semantics nodes per item |
| UX-12 | Track headers + track menu + lane flags | `timeline/{track_headers, track_menu_sheet}.dart` | UX-11 | Compact and expanded headers; lock/visibility/mute/solo per kind; rename, reorder, add, delete (confirm); toggles have `toggled:` semantics; matrix tests |
| UX-13 | Timeline gestures (scroll, zoom, select, long-press, menus, mouse) | `timeline/{timeline_gestures, timeline_view, timeline_semantics}.dart` | UX-11 | Recognizer arbitration per §8.8 (tests for each hit type, including scroll over clips on touch); pinch anchored; axis lock; context menus; multi-select mode; marquee and cursors on mouse; semantics scroll actions |
| UX-14 | Move / trim / split / delete / ripple with snapping | `timeline/{timeline_interaction, snapping}.dart`, `actions/editor_actions.dart` (edit subset) | UX-13, DOM:dryRun | Ghosts reflect `dryRun`; snap guide + haptic on engage; auto-scroll at edges; split targeting; delete vs ripple delete; gap delete; duplicate, copy, cut, paste (`editor_clipboard.dart`); each is one history entry |
| UX-15 | Playhead + transport controller + transport bar + timecode | `state/{playhead_controller, transport_controller}.dart`, `transport/*` | UX-09, ENG:preview (fake clock) | Extrapolation and scrub coalescing tests (§21.1); priority planner; timecode entry parse; frame step repeat; edit-point jumps; marker add; rebuild-budget test passes |
| UX-16 | Action registry + keyboard shortcuts + help sheet | `actions/{editor_action_registry, editor_shortcuts, shortcuts_sheet}.dart` | UX-14, UX-15 | Every §15.1 binding works on iOS-, Android- and macOS-targeted tests; the focus guard works; the help sheet is generated from the registry; toolbar tiles and menus read the same specs |
| UX-17 | Tool strip / rail + context tool sets + inspector host/dock | `toolbar/*`, `inspector/{inspector_host, inspector_dock, inspector_header, inspector_rows, keyframe_toggle, color_field}.dart` | UX-08, UX-04 | Tool sets per §9.1–9.2 (table-driven test); disabled tiles explain themselves; the dock (default/expanded) and side pane per layout; inspector re-targeting on selection change; rows generated from `PropertyKey` metadata |
| UX-18 | Markers (ruler flags, sheet, snapping, jumps) | `timeline/marker_sheet.dart` (+ ruler hooks) | UX-10, UX-14 | Add (M), move, rename, recolor, delete; snap target; ↑/↓ jumps include markers; semantics |

**Milestone M2: real preview, direct manipulation and visual inspectors**

| ID | Title | Files owned | Depends on | Acceptance criteria |
|---|---|---|---|---|
| UX-19 | Preview surface + session lifecycle + quality + fullscreen | `preview/{preview_region, preview_surface, fullscreen_preview}.dart`, `editor/editor_lifecycle.dart` | ENG:preview, IOS:preview, AND:preview | Texture shown letterboxed; status overlays; quality menu; proxies toggle; fullscreen with shared texture; refresh after resume; surface-lost recovery; wakelock while playing |
| UX-20 | Thumbnail cache + painting | `caches/thumbnail_cache.dart` (+ canvas hooks) | UX-11, ENG:thumbs | Priority queue, cancel on scroll-away, fling deferral, memory budget and trim on pressure (unit tests with the fake); painted strips (golden with fake tiles) |
| UX-21 | Waveform cache + painting | `caches/waveform_cache.dart` | UX-11, ENG:waveforms | Mip pyramid in an isolate; level selection; speed and reverse mapping; volume envelope line; golden |
| UX-22 | Canvas geometry + manipulation overlay (move/scale/rotate) + snap guides | `preview/{canvas_geometry, manipulation_overlay, manipulation_painter, snap_guides}.dart` | UX-19, DOM:boxAt | §7.3 gesture table fully implemented; transient ≤ 1 per frame; one history entry per gesture; keyframe-aware writes; handles stay inside the view; semantics actions |
| UX-23 | Transform + crop mode + mask mode + eyedropper | `preview/{crop_overlay, mask_overlay, eyedropper_overlay}.dart`, `panels/{transform, crop, mask}_panel.dart` | UX-22, ENG:editingMode, ENG:sampleColor | Crop aspect presets, rotate, flip, reset; mask rect/circle with feather and invert; eyedropper sampling throttled; all commits labeled |
| UX-24 | Adjust + Filters/LUT panels | `panels/{adjust_panel, filters_panel}.dart` | UX-17, DOM:props, PER:assets (LUT copy), ENG:lookStills | All §10.6 rows with keyframe toggles; before/after hold; apply-to-all; presets carousel with intensity; .cube import with error copy |
| UX-25 | Speed panel + curve editor | `panels/{speed_panel, speed_curve_editor}.dart` | UX-17, DOM:speed | Nine chips + custom; ramp presets; point editing with semantics; resulting duration; keep-pitch; capability notes |
| UX-26 | Keyframes panel + timeline diamonds | `panels/keyframes_panel.dart` (+ canvas diamonds) | UX-17, UX-11, DOM:keyframes | Toggle states (§9.4); list grouped by property; move by drag (snaps); nudge; delete; jump |
| UX-27 | Transitions on timeline + panel + loop preview | `panels/transitions_panel.dart` (+ canvas "+"/bowtie) | UX-14, UX-19, DOM:transitions | All 7 types + None; duration limits with explanation; direction; loop preview restores state; apply to all |
| UX-28 | Overlay (PiP) + chroma key panel | `panels/{overlay_panel, chroma_panel}.dart` | UX-22, UX-23 | Add video and image overlays on new lanes; bring forward/back; chroma with eyedropper, presets and the matte preview |
| UX-29 | Canvas/Format panel + project sheet + history sheet | `panels/canvas_panel.dart`, `flows/{project_sheet, history_sheet}.dart` | UX-09 | Aspect, background, frame rate, resolution base; rename; save now; history jump N steps = one plan patch |

**Milestone M3: text, subtitles, audio, AI**

| ID | Title | Files owned | Depends on | Acceptance criteria |
|---|---|---|---|---|
| UX-30 | Text tool + panel + font picker + animations | `panels/{text_panel, font_picker}.dart` | UX-22, DOM:text, §24 Q3/Q4 decisions | All §10.8 tabs; typing coalescing; keyboard degrade step 5; font list with search; animation in/out with preview loop; matrix tests with the keyboard inset |
| UX-31 | Subtitles lane + panel (edit, timing, split, merge, style, position) | `panels/subtitles_panel.dart` (+ canvas cue painting) | UX-14, DOM:subtitles | Cue list virtualization (3,000 cues); inline edit; nudges; split at cursor; merge; no-overlap drag; style and position; on-preview drag for custom position |
| UX-32 | SRT/VTT import & export UI | `panels/subtitles_panel.dart` (import/export section) | UX-31, DOM:subtitleCodec, ENG:exportFile | Isolate parsing; encoding fallback; error line numbers; new vs replace track; export via the share sheet and Save to Files |
| UX-33 | Audio panel + extract audio + background music | `panels/audio_panel.dart` | UX-17, DOM:audio | Volume (KF), mute, fades, keep pitch; extract audio detaches non-destructively; "Add music" flow puts the item on an audio lane at the playhead |
| UX-34 | Voiceover recording UI | `panels/voiceover_panel.dart` | UX-33, ENG:recorder | Permission explanation → OS prompt; denied state with Open Settings; countdown (reduced-motion aware); level meter; interruption keeps the partial recording; lane auto-create |
| UX-35 | Freeze, reverse, replace, clip info, background tasks | `panels/clip_info_panel.dart`, `flows/tasks_sheet.dart`, `state/tasks_controller.dart` | UX-14, ENG:jobs | Freeze inserts a still with placeholder progress; reverse progress badge + cancel + export gating; replace with trim notice; info panel fields; task indicator and sheet |
| UX-36 | Auto captions flow | `flows/captions/*` | UX-31, AI:service | §12 state machine; consent token enforced; resumable download UI; phases; cancel at every step leaves no partial track; one history entry; regenerate; failure copy |
| UX-37 | Media panel (bin) + in-app drag to timeline | `panels/media_panel.dart`, `timeline/timeline_drop_target.dart` | UX-07, UX-14 | Bin with filters and search; add at playhead; add as overlay; replace selected; drag with drop ghost + snapping; remove only when unused |

**Milestone M4: export, health, entry from player, quality gates**

| ID | Title | Files owned | Depends on | Acceptance criteria |
|---|---|---|---|---|
| UX-38 | Export sheet + controller + presets + progress | `flows/export/*` | UX-09, ENG:export, IOS:export, AND:export | Pre-checks (§11.1); presets and custom settings gated by capability; aspect-mismatch notice; estimate; destinations; non-dismissible progress; cancel confirm; completion actions (share, play in Danaview); failure fallbacks; background copy per capability; notification permission flow (Android 13+) |
| UX-39 | Missing media banner + relink sheet + recovery/migration dialogs | `flows/relink/*`, `state/media_health_controller.dart`, `projects/recovery_banner.dart` | PER:mediapool, PER:recovery | §13 fully; relink validation outcomes; folder auto-relink report; one history entry; recovery dialog on open; newer-schema block |
| UX-40 | Player "Edit" action + launcher + handoff | `danaview_controls_overlay.dart`, `danaview_player_screen.dart`, `player_controller.dart` (handoff ext), `app/editor_launcher.dart` | UX-02, UX-08, PER:repo, ENG:compatibility | Shown only for local media on supported platforms; E shortcut; unsupported-format dialog with platform-specific copy; untouched-project reuse; "Preparing editor…" after 300 ms; opens at the exact position; return restores player paused + orientation; pause vs release mode by capability; 280 px top-bar test |
| UX-41 | Legal texts + licenses screen + platform strings | `more/legal_texts.dart`, new `more/danaview_licenses_screen.dart`, About row; Info.plist/Manifest entries (with IOS/AND) | AI:service (host), IOS/AND | §20 text in place with the exact host; the host-consistency test; effective date; custom licenses screen (no Material `LicensePage`); usage strings present |
| UX-42 | Accessibility pass | all editor widgets; `timeline/timeline_semantics.dart` | M1–M3 | Guideline tests pass; custom actions on clips, keyframes, transitions and markers; announcements; reduced motion; VoiceOver and TalkBack manual script executed on device (checklist in the test plan) |
| UX-43 | Overflow matrix suite | `test/overflow/*` | M1–M3 | Full matrix (§19.2) green nightly; PR subset green; long-content fixtures |
| UX-44 | Performance instrumentation + profile tests | `integration_test/perf_*`, debug rebuild counters | M1–M3 | §22 budgets measured on the low-tier device; report artifact in CI |
| UX-44b | Timeline picture-tile cache (conditional) | `timeline/timeline_tiles.dart` | UX-44 (budget miss) | Scroll/follow UI-thread time within budget; invalidation tests; visual parity with direct painting (golden) |
| UX-45 | On-device E2E suite | `integration_test/e2e_*` | M4 | §21.5 scenarios 1–7 pass on the iOS and Android device set |
| UX-46 | README + docs | `README.md`, `docs/v1.1/video-editor/user-guide.md` (shortcuts, features) | M4 | Architecture tree updated; editor shortcuts table; user guide |
| UX-47 | Store metadata (fastlane) | `ios/fastlane/metadata`, `android/fastlane/metadata`, `publishing/screenshots` | M4 | Descriptions mention editing and auto captions; privacy labels unchanged; screenshots updated |

---

## 24. Risks, open questions and platform claims to verify

### 24.1 Platform/API claims and confidence

| # | Claim relied on | Confidence | Verify how / owner |
|---|---|---|---|
| P1 | Flutter `Texture` widgets display native frames. iOS: `FlutterTexture.copyPixelBuffer`. Android: `TextureRegistry.createSurfaceProducer()`, whose surface can be lost on background. The callback names changed around Flutter 3.27 (`onSurfaceAvailable` / `onSurfaceCleanup`) | High (mechanism) / **Medium (exact Android callback names on 3.44)** | Check `TextureRegistry.java` in the 3.44 engine; engine areas |
| P2 | One texture id may back two `Texture` widgets at once (fullscreen preview) | Medium-high | Spike in UX-19; fallback: move the single `Texture` into the fullscreen route |
| P3 | `PopScope(canPop: false)` disables the iOS edge back-swipe on the route | Medium-high | Widget test with `CupertinoPageTransitionsBuilder` (the theme already uses it) |
| P4 | `ScaleGestureRecognizer` gives `rotation`, `horizontalScale`, `focalPointDelta` and handles trackpad `PointerPanZoom*` | High | Unit test |
| P5 | An ancestor `Shortcuts` binding Space/Backspace pre-empts text input unless the action is disabled and `consumesKey` is false | High | Focus-guard test (UX-16) |
| P6 | iPadOS's hardware-keyboard shortcut overlay lists only `UIKeyCommand`s; Flutter apps get key events through `pressesBegan`, so ⌘ combos reach Flutter, but no system overlay is shown | Medium | Device check on iPad; in-app sheet covers it either way |
| P7 | `RenderObject.assembleSemanticsNode` / `CustomPainterSemantics` support per-node `customSemanticsActions` | High | Semantics tests |
| P8 | `SemanticsService.announce` may be deprecated in recent Flutter in favor of a view-aware `sendAnnouncement` | **Medium** | Use whichever 3.44 exposes; wrap in `editorAnnounce()` |
| P9 | `PaintingContext.addLayer` can re-add cached `PictureLayer`s; Impeller re-renders display lists each frame (no picture raster cache), which is still cheap for rects, images and lines | Medium-high | Profile in UX-44 |
| P10 | `ui.instantiateImageCodec` decodes off the UI isolate | High | n/a |
| P11 | AVFoundation can't demux MKV/WebM/AVI; Media3 demuxes MKV/WebM (codec support per device) | High | Engine `compatibility()` tables |
| P12 | iOS 26 `BGContinuedProcessingTask` allows continued user-initiated work with system progress UI; background GPU depends on device | **Medium** | iOS area |
| P13 | Android 15 `mediaProcessing` FGS type (time-limited); Android 14 needs another declared type | Medium-high | Android area |
| P14 | Android Photo Picker URIs can be persisted with `takePersistableUriPermission` | **Medium** | Android / Persistence areas |
| P15 | Media3 `CompositionPlayer` is `@UnstableApi`; multi-sequence (overlay) preview and effect parity vary by release | **Medium** | Android area; UI depends only on capabilities and events |
| P16 | Whisper ggml model sizes (e.g. base-q5_1 ≈ 57 MB); hosted on huggingface.co by the whisper.cpp project | Medium | AI area. UI reads the size and host from `SpeechModelSpec` |
| P17 | YouTube recommended SDR bitrates (1080p: 8 / 12 Mbps; 4K: 35–45 / 53–68 Mbps) | Medium | Export owner; presets are hints |
| P18 | Short-form length limits change often (Shorts, Reels, TikTok) | Low | **Not enforced** in UI by design |
| P19 | `Icons.movie_edit`, `Icons.compare_rounded`, `Icons.join_inner_rounded`, `Icons.diamond_rounded/_outlined`, etc. exist; `Icons.transition_rounded` doesn't | Verified (SDK grep) | n/a |
| P20 | Riverpod 2.6 `StateNotifierProvider.autoDispose.family` + `ref.keepAlive()`; `StateNotifier` is legacy in Riverpod 3 | High | Migration later |

### 24.2 Open questions (need owner or sibling decisions)

| # | Question | Recommendation | Decider |
|---|---|---|---|
| Q1 | Desktop entry points: hidden or "coming soon"? | Hidden (flag in place) | Owner |
| Q2 | Editor minimum iOS version | UI handles any value via `EditorUnsupported(reason)` | iOS area |
| Q3 | **Who renders text** (text items, subtitles burn-in): Flutter `ui.Paragraph` rasterized to bitmaps with glyph boxes and passed to native, or native CoreText / Android `StaticLayout`? | **Flutter-rendered**: identical metrics for handles and output on both platforms, same fonts, one implementation. Bitmaps are produced before export starts, so encoding needs no Dart. Typewriter uses glyph boxes as reveal masks. Native-rendered text needs a `measureText` channel and parity tests | Domain + engines (synthesis) |
| Q4 | Owner rule "Figtree only font" vs "Font selection" for text overlays | Figtree stays the only **UI** font. Bundle a curated OFL set (8–12 families, ~3–5 MB) used **only in user content**; the font picker previews each family in itself | **Owner** |
| Q5 | "Cut" meaning; "Fade" vs "Cross dissolve" semantics | Cut = ⌘X clipboard cut. Fade = outgoing fades out, then incoming fades in, through the canvas background (Domain to confirm) | Owner + Domain |
| Q6 | iOS Photos import: copy into app storage vs `PHAsset` reference | Copy (no library permission; robust); UI copy prepared for both | Persistence |
| Q7 | External drag-and-drop from other apps on iPad/Android | Post-v1 (plugin) | Owner |
| Q8 | Drop/move overlap policy (auto new lane vs reject vs overwrite) | Auto new lane (non-destructive) | Domain |
| Q9 | "Auto-detect language" option in auto captions | Offer it only as a secondary row if the AI area supports it; the user's choice stays primary | AI + Owner |
| Q10 | Editing while exporting | Blocked in v1 (modal export) | Owner |
| Q11 | Center-locked playhead as the touch default | Yes (mobile editor convention); toggle available | Owner |
| Q12 | Custom speed range | 0.1×–10× (clamped by capability) | Domain + engines |
| Q13 | Model host: Hugging Face vs a vecvel-controlled CDN | Either works; the policy text is parameterized. A vecvel host gives control over availability and lets the policy name vecvel | Owner + AI |

### 24.3 Risks

| Risk | Impact | Mitigation |
|---|---|---|
| iOS can't edit MKV/WebM/AVI without FFmpeg, though the player plays them | Users hit "can't be edited" often | Clear, platform-specific copy before project creation; Android handles MKV/WebM; documented in the user guide |
| Preview performance or parity on low-tier devices (multi-track, LUT, chroma, text) | Laggy editing | Auto quality degrade, proxies, preview-quality UI, perf budgets on real low-tier hardware nightly |
| Two decoding engines in memory (mpv + editor) | OOM on 3–4 GB devices | `PlayerHandoffMode.release` on low-memory devices |
| Gesture conflicts (scroll vs drag vs back-swipe vs sheet drag) | Frustration | Eager handles, long-press-to-drag on touch, PopScope, device test scripts |
| Scope: everything ships in one release | Schedule | Fakes-first so UI tickets run in parallel with native; internal milestones; one action registry avoids rework |
| Text metrics mismatch (Q3) | Handles don't match rendered text | Decide Q3 early; parity test (handle box vs rendered alpha bounds) |
| Accessibility of a painted timeline | Store and a11y regressions | Semantics built in from UX-11; guideline tests; manual VoiceOver/TalkBack script |
| Channel throughput for transients and clock | Jank | Coalescing and rate limits (§17.1); FFI path open later |
| Store policy (Google Play media permissions, privacy strings) | Rejection | §20.3 checklist; photo picker only |

---

## Appendix A: Feature traceability (every owner-listed feature → UI surface → ticket)

**Project & timeline**

| Feature | UI | Ticket |
|---|---|---|
| Create, save, rename, duplicate, reopen projects | Projects screen §5, Project sheet §6.4, ⌘S | UX-06, UX-29, UX-16 |
| Non-destructive editing | Every edit is a command (§16); originals never touched (§4.4, §13) | UX-09 |
| Multi-track timeline; multiple video/audio tracks; text, subtitle, image/overlay tracks | §8.3 lanes, track menu §8.10 | UX-11, UX-12 |
| Timeline zoom + horizontal scrolling | §8.4, §8.8 | UX-10, UX-13 |
| Playhead + time ruler | §7.8, §8.5, §8.7 | UX-10, UX-15 |
| Snapping to clips, markers, playhead | §8.9 | UX-14 |
| Clip selection + multi-selection | §8.8, §8.9 | UX-13, UX-14 |
| Track lock/unlock, visibility, mute/solo | §8.3, §8.10 | UX-12 |
| Clip thumbnails, audio waveforms | §17.3, §17.4 | UX-20, UX-21 |
| Clip duration and metadata | Label chip §8.6, Info panel §8.11 | UX-11, UX-35 |
| Undo/redo history | Top bar, history sheet §14 | UX-09, UX-29 |

**Basic editing**

| Feature | UI | Ticket |
|---|---|---|
| Import video, audio, images | New project sheet §5.3, Media panel §10.1 | UX-07, UX-37 |
| Cut (⌘X), trim, split, delete, duplicate, copy/paste, move | §8.9, §14.4, §15.1 | UX-14 |
| Ripple delete, ripple insert | §8.9 (ripple mode, Shift+Delete) | UX-14, UX-37 |
| Replace media | §10.15 | UX-35 |
| Freeze frame, reverse video | §10.15 | UX-35 |
| Frame-accurate seeking | §7.6 frame step and timecode entry, §7.8 exact seek | UX-15 |
| Markers | §8.5 | UX-18 |

**Video transform**

| Feature | UI | Ticket |
|---|---|---|
| Position, scale, rotation, flips, crop, opacity, reset | Transform panel §10.2, crop §7.5 | UX-23 |
| Aspect ratio | Canvas panel §10.14, new project §5.3, export notice §11.2 | UX-29 |
| Direct manipulation in preview | §7.3 | UX-22 |

**Speed**

| Feature | UI | Ticket |
|---|---|---|
| 0.25×–4× presets, custom | §10.3 | UX-25 |
| Speed ramping | Curve editor §10.3 | UX-25 |
| Maintain pitch | Keep pitch switch §10.3/§10.4 | UX-25, UX-33 |
| Proper A/V sync | Native clock master §7.8; engine contract §2.3 | UX-15 (+ engines) |

**Text**

| Feature | UI | Ticket |
|---|---|---|
| Add text; font, size, bold/italic, alignment, color, opacity, letter/line spacing, background, stroke, shadow | Text panel §10.8 | UX-30 |
| Position, rotation, scale | Direct manipulation §7.3, Transform §10.2 | UX-22, UX-23 |
| Text duration | Edit tab duration + timeline trim | UX-30, UX-14 |
| Animations: Fade, Slide, Scale, Typewriter | Animation tab §10.8 | UX-30 |

**Subtitles**

| Feature | UI | Ticket |
|---|---|---|
| Create, edit text, adjust start/end, move, split, merge, delete | §10.9 + subtitle lane | UX-31 |
| Styling, positioning, subtitle track | §10.9 style/position, lane §8.3 | UX-31 |
| Import/Export SRT, VTT | §10.9 | UX-32 |
| Burn into video | §10.9, export §11.2 | UX-31, UX-38 |

**AI subtitles**

| Feature | UI | Ticket |
|---|---|---|
| Generate from video/audio; user selects language | §12.2 steps 1, 4 | UX-36 |
| Extract audio; speech-to-text; timestamps; segmentation | Progress phases §12.2 step 5 (AI/native do the work) | UX-36 (+ AI) |
| Insert into timeline, fully editable | §12.2 step 6, §12.3 | UX-36, UX-31 |
| Regenerate | §12.3 | UX-36 |
| Export SRT/VTT, burn in | §10.9, §11.2 | UX-32, UX-38 |
| No other AI features | Only the "Auto captions" entry exists | — |

**Audio**

| Feature | UI | Ticket |
|---|---|---|
| Multiple tracks, import, background music | §8.3, Audio tool §9.1, Media panel | UX-12, UX-33, UX-37 |
| Extract audio from video | §10.4 | UX-33 |
| Trim, split, move, duplicate, delete audio | §8.9 (all item kinds) | UX-14 |
| Volume, fades, mute, waveform | §10.4, §17.4 | UX-33, UX-21 |
| Voice recording where supported | §10.5 | UX-34 |
| Audio synchronization | Shared timeline clock; extract audio keeps sync (same media) | UX-33 (+ engines) |

**Video effects; color & LUT**

| Feature | UI | Ticket |
|---|---|---|
| Brightness … Tint, sharpness, blur, vignette, opacity | Adjust panel §10.6 (single home, §10.0) | UX-24 |
| Color presets, LUT, .cube import, intensity | Filters panel §10.7 | UX-24 |

**Transitions**

| Feature | UI | Ticket |
|---|---|---|
| Fade, cross dissolve, dip to black/white, slide, wipe, zoom; duration; direction; preview | §10.12, timeline "+"/bowtie §8.6 | UX-27 |

**Picture-in-picture, chroma key, masking, keyframes**

| Feature | UI | Ticket |
|---|---|---|
| Video/image over video, multiple overlays, resize/move/rotate/crop/opacity, independent timeline | §10.13 + overlay lanes + §7.3 | UX-28, UX-22, UX-23 |
| Green screen, custom key color, similarity, smoothness, spill, preview | §10.10 + eyedropper §7.5 | UX-28 |
| Rectangle/circle mask, position, size, feather, opacity | §10.10 + mask overlay §7.5 | UX-23 |
| Position/scale/rotation/opacity/volume/basic effect keyframes; add/remove/move/edit; linear | §9.4 toggles, §10.11, timeline diamonds | UX-26 |

**Preview**

| Feature | UI | Ticket |
|---|---|---|
| Real-time preview, play/pause, frame/time seeking, current time/duration, timeline-synced playback | §7.1, §7.6, §7.8 | UX-19, UX-15 |
| Fullscreen preview, preview quality options | §7.7 | UX-19 |

**Export & rendering**

| Feature | UI | Ticket |
|---|---|---|
| MP4, MOV where supported, H.264, H.265 where supported | §11.2 capability-gated | UX-38 |
| Resolution, FPS, bitrate, audio bitrate, quality presets, custom | §11.2 | UX-38 |
| YouTube, Shorts, Instagram, TikTok presets | §11.2 table | UX-38 |
| Progress, cancel, background, hardware acceleration | §11.4–11.6 | UX-38 |

**Project management**

| Feature | UI | Ticket |
|---|---|---|
| Autosave, manual save, recovery, duplication, deletion, schema migration | §14.3, §5.2, §13.3–13.4 | UX-09, UX-06, UX-39 |
| Missing media detection, relink | §13.1–13.2 | UX-39 |
| Project media management | Media panel §10.1, Storage §4.8 | UX-37, UX-05 |
| Originals never modified/moved/renamed/deleted | §1, §4.4, §13.2, §20 copy | all |

**Performance**

| Feature | UI | Ticket |
|---|---|---|
| Thumbnail/waveform caching, lazy timeline rendering, efficient updates, large projects | §17 | UX-11, UX-20, UX-21, UX-44, UX-44b |
| Proxy media | §17.7, settings §4.8 | UX-19, UX-35, UX-05 |
| Background processing, isolates | §17.1 | UX-09, UX-21, UX-32 |
| Desktop / mobile optimization | Layout kinds §6, budgets §22 | UX-08, UX-44 |

**Desktop UX (works with any hardware keyboard or mouse now; desktop editor later)**

| Feature | UI | Ticket |
|---|---|---|
| Space/K, arrows, S, Delete, ⌘Z, ⌘⇧Z, ⌘S, ⌘C, ⌘V, ⌘D | §15.1 | UX-16 |
| Drag and drop media | In-app §15.3; external desktop later | UX-37 |
| Mouse timeline controls | §8.4, §8.8, §15.4 | UX-13 |

**Mobile UX**

| Feature | UI | Ticket |
|---|---|---|
| Touch timeline, drag clips, trim handles, split controls, pinch-to-zoom, long press | §8.8–8.9 | UX-13, UX-14 |
| Touch preview controls; gesture-based position/scale/rotation | §7.3, §7.6 | UX-22, UX-15 |
| Bottom editing toolbar, tool tabs, bottom sheets | §9, §6.3 | UX-17 |
| Touch-friendly controls, mobile-optimized inspector | §9.3 dock, §19.1 targets | UX-17, UX-42 |

---

## Appendix B: Interface checklist for the merge (UI ↔ other areas)

| Interface | Direction | Must provide | Section |
|---|---|---|---|
| `EditProject` immutability with identity sharing | Domain → UI | unchanged tracks and items keep `identical` instances across commands | §8.2, §16.6 |
| `dryRun(EditCommand)` | Domain → UI | resulting positions, `createsTrack`, rejection; ≤ 1 ms at 1,000 items | §8.9 |
| `PropertyKey` metadata | Domain → UI | name, unit, min, max, default, step, keyframable | §9.3, §10 |
| `boxAt` + `TextMetricsProvider` | Domain/Q3 → UI | oriented box in canvas px at time t | §7.2 |
| RenderPlan compile/diff, isolate-safe | Domain → UI → Engines | pure function on sendable data | §16.5 |
| `ProjectRepository`, `MediaPoolService` | Persistence → UI | §2.2 incl. `findUntouchedProjectFor`, availability stream, relink check | §5, §13 |
| `PreviewSession` clock, seek ack, transients, editing modes, events | Engines → UI | §2.3 semantics (seq, displayedFrameTime, coalescing) | §7 |
| Thumbnails (tiles, cancel), waveforms (peaks) | Engines → UI | §2.3 keys and formats | §17.3–17.4 |
| Export job + capabilities | Engines → UI | progress phases, ETA inputs, failure kinds, background kind | §11 |
| Media jobs (proxy, reverse, freeze) | Engines → UI | progress + cancel + result asset id | §10.15, §17.7 |
| Voice recorder | Engines → UI | permission state, levels stream, interruption events | §10.5 |
| `pickMedia`, `exportFile`, `compatibility` | Engines → UI | native pickers incl. Photos/Gallery; share/save; edit-compatibility reason strings | §5.3, §4.4 |
| `TranscriptionService` + `UserConsent` | AI → UI | languages, model spec (size, host, sha), resumable download, phases, cue drafts | §12 |
| AI ↔ native audio extraction | AI → Engines (UI only shows phase) | PCM 16 kHz mono from the RenderPlan audio mix or media range | §12.2 step 5 |
| Legal host string | AI → Legal text | `SpeechModelSpec.host` equals the string in the privacy policy (test) | §20 |
