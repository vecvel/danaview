# Danaview Editor: Domain Model, Editing Operations, Persistence and RenderPlan

> **Area:** the pure-Dart editing core. It covers the timeline model, time math, editing commands, undo/redo, validation, keyframe and geometry evaluation, project storage (autosave, recovery, migration), media management (import policy, fingerprints, missing media, relink, garbage collection), SRT/VTT and `.cube` codecs, and the platform-neutral **RenderPlan** and **ExportSettings** that the native engines consume.
> **Status:** design draft for the Editor release. This document contains no production code. Dart, Swift and Kotlin snippets are interface sketches.
> **Date:** 2026-10-07. **Baseline:** `main` @ `19cae59`. Flutter 3.44.2, Dart 3.12.2. Locked versions: `meta` 1.18.0, `collection` 1.19.1, `crypto` 3.0.7, `path` 1.9.1 (from `pubspec.lock`).
> **Sibling docs** in `docs/v1.1/video-editor/design/`: `ux.md` (screens, controllers, timeline UI; its §2 states the minimum it needs from this area), `ai.md` (whisper.cpp captions; its §10 and §17 propose types this area owns), and the iOS/Android engine docs (file names not final). **This document is authoritative for the type names it defines.** §17 lists every place where a sibling doc's assumption differs from what is defined here.
>
> **Markers.** **[VERIFIED]** means checked against the repo or the SDK today. **[VERIFY]** means believed but not checked. Each one has a ticket acceptance criterion. **[DECISION]** marks a choice that the lead architect or the owner should confirm.

---

## 0. Decisions at a glance

1. **New package `packages/danaview_editor_core`, pure Dart.** It has no Flutter import, so every model, command, codec and compiler runs in isolates and under `dart test`. Dependencies: `meta`, `collection`, `crypto`, `path`, `characters`. File I/O (`dart:io`) is confined to `lib/src/store/`, and a test enforces that.
2. **Time is an integer count of microseconds (`TimeUs = int`) with a rational `FrameRate`.** Every timeline edge sits exactly on the project frame grid, where frame *k* starts at `ceil(k·10⁶·den/num)` µs. Source times are not quantized to the project grid. The compiler adds a fixed +500 µs sampling bias to video source maps, so both engines pick the same source frame using their default "latest PTS ≤ t" rule (§3).
3. **The model is immutable and shares structure.** Unchanged `Track` and item instances stay `identical` across commands. Item lists are copy-on-write per track. There is no persistent-collection dependency: a 500-item lane copies 500 pointers, which takes microseconds.
4. **The media pool lives outside the timeline subtree.** History snapshots cover `Timeline` (settings, tracks, markers). Pool additions (imports, recordings, derived assets) are *sticky*: undo never removes media from the bin. Pool changes that the user should be able to undo (relink, remove from project) are recorded as `PoolDelta`s inside the history entry.
5. **Undo/redo stores snapshots, not inverse commands.** Because the model is immutable, an entry is two root pointers plus an optional pool delta. Correctness holds by construction, compound edits and AI caption batches are free, and memory stays bounded through sharing (§7).
6. **Commands are pure: `(Timeline, EditContext) → CommandResult | EditRejection`.** A rejection is data, never an exception. `dryRun` uses the same code path. New ids come from `EditContext.ids`, so a command's result is deterministic in tests.
7. **Overlap policy:** two items on one lane never overlap. A non-ripple move, paste or insert into occupied space goes to the nearest free lane of the same kind, and a new lane is created if none is free (ux.md Q8). Ripple affects the edited lanes plus their linked partners.
8. **Transitions are centered on the cut and use handles.** Timeline positions don't change. The RenderPlan has **no transition primitive**. The compiler *lowers* every transition, fade, text animation, speed ramp, dip color and blurred background into extended layers, piecewise-linear keyframes, masks and solid layers. Engines implement one animation primitive (linear keyframes) and a small fixed effect set, so preview and export can't drift between iOS and Android (§12).
9. **Text layout belongs to Flutter, not the engines [DECISION, answers ux.md Q3].** The preview draws text and subtitle layers in a Flutter overlay above the native texture. This is valid because text and subtitles are always the top compositing bands (§4.3). For export, the same layout code rasterizes PNG sprites, and the plan references them. The plan still carries the full `TextLayoutSpec`, so a native text renderer can be added later without a schema change.
10. **Transport: the RenderPlan is versioned JSON (UTF-8 bytes) carried inside the engine's typed control API (Pigeon recommended).** The JSON Schema in `danaview_editor_core/schema/` is the single contract. A shared fixture corpus is decoded by the Dart, Swift and Kotlin contract tests (§12.9).
11. **A project is a bundle under Application Support, never under `Documents`.** The file is a two-line format: a header line (schema, sizes, SHA-256) followed by a body line. Writes go to a temp file, then fsync, rotate `.bak`, and rename. Autosave writes a two-slot journal. Manual, exit and background saves write the main file. Crash recovery means a journal newer than the main file. Migrations are pure functions on raw JSON, with a backup taken first.
12. **Originals are never modified, moved, renamed or deleted.** Every delete goes through one `OwnedFileDeleter`, which canonicalizes paths and refuses anything outside the editor roots or any asset whose ownership is `external`. App-owned picker temp copies move into a content-addressed managed store that projects share. iOS Files and Android documents are referenced in place, through bookmarks or persisted URI grants. Mark-and-sweep GC reclaims unreferenced copies and grants.
13. **Desktop later, with no core changes.** Nothing in the core is mobile-specific. Platform specifics sit behind `MediaAccessPort`, which the engine package implements, and the RenderPlan is engine-neutral.

---

## 1. Scope and ground truth

**This area owns:** `danaview_editor_core` (all of it), the project file format, the RenderPlan JSON Schema and its fixtures, the export presets table, and the Android backup-rules XML, co-owned with the Android area.
**It does not own:** widgets and Riverpod controllers (ux.md), native rendering, decoding, picking and jobs (engine docs), or whisper and segmentation (ai.md).

| Fact [VERIFIED in repo] | Where | Consequence |
|---|---|---|
| `danaview_domain` is pure Dart (only `meta`); `danaview_data` depends on Flutter (`path_provider`, and `debugPrint` in `MediaInspector`) | `packages/*/pubspec.yaml` | The core must not depend on `danaview_data`. Store roots are injected as plain paths that the app builds from `AppStorage`. |
| `MediaIdentityService.computeQuickHash` = sha1(first 64 KB + last 64 KB + `:size`) | `danaview_data/lib/src/scanner/media_identity.dart` | The same algorithm becomes `MediaFingerprint.quickHash`, reimplemented in core and tested for equality, so player, editor and AI caches agree. |
| `AppStorage.appDataDirectory` = `getApplicationSupportDirectory()`; the cache dir is `getTemporaryDirectory()` | `danaview_data/lib/src/storage/app_storage.dart` | Roots: `<support>/danaview/editor/` and `<cache>/danaview/editor/`. ai.md uses `danaview/speech/`. |
| `LibraryStorage` moves only the app's own temp picker copies into `Documents/Imported`; `Documents` is the "On This Device" library | `library_storage.dart` | Files under `Documents` are the **user's library = originals**. The editor references them through `AppRelativeLocator` and never moves them. Editor files never go into `Documents`. |
| `LibraryStorage.resolveStoredPath` rebases absolute paths after an iOS container UUID change | same | Avoided by design: app-internal files are stored as root-relative paths. |
| Android `MainActivity.copyContentUriToCache` copies incoming `content://` files into the cache; iOS `AppDelegate` calls `startAccessingSecurityScopedResource` for in-place opens | `MainActivity.kt`, `AppDelegate.swift` | Player "Edit" can see a cache copy (Android), which must be copied into the managed store because the cache is purgeable, or an in-place URL (iOS), which gets a bookmark. See §10.1. |
| No Android backup rules exist (`allowBackup` defaults to true) | `AndroidManifest.xml` | Large media copies would break Auto Backup's 25 MB quota. Exclusion rules are added (DOM-28). |
| No test CI workflow; tests use `test` (domain) and `flutter_test` | `.github/workflows`, `test/` | DOM-01 adds `editor-core.yml` running `dart test` for the core. |

---

## 2. Package and file layout

```
packages/danaview_editor_core/
  pubspec.yaml            # sdk ^3.12; deps: meta, collection, crypto, path, characters; dev: test, lints
  schema/
    project.v1.schema.json        # project body JSON Schema (documentation + test validation)
    render_plan.v1.schema.json    # THE engine contract
  lib/
    model.dart            # exports: time, ids, project, timeline, tracks, items, props, pool, keyframes
    ops.dart              # exports: commands, rejections, session, history, snapping, selection
    eval.dart             # exports: time maps, keyframe eval, geometry, text animation eval
    formats.dart          # exports: srt/vtt codec, cube parser, vlut
    plan.dart             # exports: RenderPlan types, compiler, diff, export settings, presets
    store.dart            # exports: repository, media pool service, ports, autosave (dart:io)
    src/
      time/      time_us.dart frame_rate.dart time_range.dart timecode.dart
      ids/       ids.dart id_generator.dart
      model/     edit_project.dart timeline.dart project_settings.dart track.dart track_kind.dart
                 items.dart media_clip.dart text_item.dart subtitle_cue.dart transition.dart marker.dart
                 speed.dart visual_props.dart color_adjust.dart look.dart chroma_key.dart mask.dart
                 audio_props.dart text_style.dart text_animation.dart subtitle_style.dart
                 caption_provenance.dart links.dart view_state.dart
        pool/    media_pool.dart media_asset.dart media_locator.dart media_probe.dart
                 media_fingerprint.dart derived_spec.dart
        keyframes/ property_key.dart property_registry.dart keyframe_track.dart keyframe_set.dart
      eval/      clip_time_map.dart speed_math.dart evaluate.dart geometry.dart text_layout_spec.dart
                 text_animation_eval.dart transition_limits.dart
      validate/  invariants.dart validator.dart repair.dart
      ops/       edit_command.dart (library; sealed) + parts: commands/track_commands.dart
                 commands/clip_commands.dart commands/ripple.dart commands/speed_commands.dart
                 commands/property_commands.dart commands/keyframe_commands.dart commands/text_commands.dart
                 commands/subtitle_commands.dart commands/caption_commands.dart
                 commands/transition_commands.dart commands/marker_commands.dart commands/composite.dart
                 rejections.dart outcome.dart edit_context.dart placement.dart
                 clipboard.dart snapping.dart selection.dart dry_run.dart requantize.dart
      session/   edit_session.dart history.dart transaction.dart pool_change.dart
      formats/   subtitle_codec.dart srt.dart vtt.dart text_decoding.dart cube_lut.dart vlut.dart
      plan/      render_plan.dart plan_json.dart compiler.dart lowering_transitions.dart
                 lowering_text.dart lowering_audio.dart plan_diff.dart plan_memo.dart
                 sprite_requests.dart export_settings.dart export_presets.dart bitrate.dart
      codec/     project_json.dart fragment_cache.dart schema_version.dart
        migrations/ migration.dart migrations.dart (registry) m0001_example.dart
      store/     store_roots.dart store_fs.dart atomic_file.dart dnproj_format.dart owned_file_deleter.dart
                 project_repository.dart file_project_repository.dart project_summary.dart
                 autosave_scheduler.dart journal.dart recovery.dart
                 media_pool_service.dart media_access_port.dart import_policy.dart managed_store.dart
                 availability.dart relink.dart gc.dart storage_report.dart
  test/  (mirrors src/) + fixtures/{projects,render_plans,srt,vtt,cube}/ + fuzz/ + purity_test.dart
  benchmark/ apply_bench.dart compile_bench.dart codec_bench.dart
```

**Dependency rules** (enforced by `test/purity_test.dart`, which parses imports):
* Nothing under `lib/src` imports `package:flutter` or any `danaview_*` package.
* Only `lib/src/store/**` may import `dart:io`. Codecs take `Uint8List`/`String` and use `dart:convert` only. `model`, `ops`, `eval`, `formats`, `plan` and `codec` stay I/O-free and isolate-safe.
* `danaview_editor` (UX), `danaview_transcription` (AI) and the engine package depend on the core. The core depends on none of them.

---

## 3. Time

```dart
typedef TimeUs = int;                      // microseconds; 64-bit on the Dart VM/AOT. Max project 24 h.

final class FrameRate {
  const FrameRate(this.num, this.den);     // 24000/1001, 24/1, 25/1, 30000/1001, 30/1, 50/1, 60000/1001, 60/1
  final int num, den;
  static const supported = [...];          // v1 project rates; any rational 1..240 decodes (future)
  TimeUs timeOfFrame(int k) => ceilDiv(k * 1000000 * den, num);
  int frameIndexOf(TimeUs t) => floorDiv(t * num, 1000000 * den);
  TimeUs quantize(TimeUs t) => timeOfFrame(frameIndexOf(t));           // floor to frame start
  TimeUs quantizeNearest(TimeUs t);                                     // nearest frame start
  TimeUs framesToUs(int n) => timeOfFrame(n);                           // duration of n frames from 0
  bool isOnGrid(TimeUs t) => quantize(t) == t;
  double get fps => num / den;
}
final class TimeRange { const TimeRange(this.start, this.end); final TimeUs start, end; // half-open [start,end)
  TimeUs get duration; bool contains(TimeUs t); bool overlaps(TimeRange o); TimeRange shift(TimeUs d); }
abstract final class Timecode {           // display/parse; frame-index based, non-drop-frame
  static String clock(TimeUs t);                            // m:ss / h:mm:ss
  static String frames(TimeUs t, FrameRate r);              // hh:mm:ss:ff (ff = frameIndex % round(fps))
  static TimeUs? parse(String s, FrameRate r);              // accepts m:ss, h:mm:ss(.mmm), hh:mm:ss:ff
}
```

* **Round trip.** `frameIndexOf(timeOfFrame(k)) == k` holds for every k, and `frameIndexOf(timeOfFrame(k+1) − 1) == k`. Both follow from `ceil` and from frame durations > 1 µs. They are property-tested over all supported rates and k up to 24 h. Products stay below 2.1·10¹⁶, well inside int64.
* **Grid invariant.** Every item `start` and `end`, marker, keyframe and transition boundary satisfies `isOnGrid`. Durations are therefore whole frame counts. Changing the frame rate runs `requantize` (§6.6).
* **Why integers and not a rational type.** AVFoundation `CMTime(value:, timescale: 1_000_000)` and Media3 (`…Us` everywhere) consume µs exactly. Integer ordering, hashing and JSON need no normalization. A 29.97 grid in µs is exact *by construction* because frame starts are computed, not accumulated. A rational `Time` type would add allocation to every comparison in the hottest paths (dry runs, snapping) and buy nothing at the engine boundary.
* **Source-frame rule (frame-accurate seeking).** Timeline frame *k* is presented at `t_k = timeOfFrame(k)`. For each video layer the engine shows the source sample with the greatest PTS ≤ `map(t_k)`. The compiler adds `kVideoSampleBiasUs = 500` to video map source times, which is well under half of the shortest frame (240 fps ⇒ 4,167 µs). This absorbs µs rounding of container timescales (for example 1001/30000 s ticks) without either engine needing a custom tolerance. Audio maps have no bias. Seek acknowledgements report `t_k` (ux.md §2.3 `SeekAck.displayedFrameTime`).
* **Display.** Timecodes count frame *indices*. 29.97/59.94 show non-drop-frame `ff`. Drop-frame display is out of scope for v1.

---
## 4. Model

### 4.1 Ids

```dart
extension type const ProjectId(String value) {}   // 'pr_' + 12 base62 (Random.secure; ~71 bits)
extension type const TrackId(String value) {}     // 'tr_…'
extension type const ItemId(String value) {}      // 'it_…'  media clips, text items, subtitle cues
extension type const MediaId(String value) {}     // 'md_…'
extension type const MarkerId(String value) {}    // 'mk_…'
extension type const TransitionId(String value) {}// 'tx_…'
extension type const LinkId(String value) {}      // 'ln_…'
abstract interface class IdGenerator { T next<T>(IdKind kind); }   // SecureIdGenerator; SeededIdGenerator (tests)
```

Ids are unique project-wide. Items, tracks and markers are never re-identified, except when Paste or Duplicate mint new ids.

### 4.2 Project root

```dart
@immutable final class EditProject {
  final ProjectId id;
  final ProjectMeta meta;          // name, createdAt, updatedAt, origin (empty | fromPlayer{fp, path} | duplicatedFrom), editCount
  final Timeline timeline;         // history-tracked subtree (§7)
  final MediaPool pool;            // NOT snapshot by history (sticky adds; undoable deltas only, §7.2)
  final ViewState view;            // playhead, zoom, scroll, ripple/snap modes, lane heights, last export settings
  final int docRevision;           // +1 on every persisted change (timeline, pool, view, meta)
  // ux.md §2.1 convenience getters
  ProjectSettings get settings => timeline.settings;
  List<Track> get tracks => timeline.tracks;
  List<Marker> get markers => timeline.markers;
  MediaPool get media => pool;
  TimeUs get duration => timeline.duration;              // max item end over all tracks; cached
  int get revision => timeline.revision;
  TimelineIndex get index;                               // lazy: ItemId -> (trackIdx, itemIdx); MediaId -> usage count
}

@immutable final class Timeline {
  final ProjectSettings settings;
  final List<Track> tracks;        // canonical order = compositing order inside bands (§4.3)
  final List<Marker> markers;      // sorted by time
  final int revision;              // session-monotonic stamp (§7.2): never reused, even across undo
}

@immutable final class ProjectSettings {
  final CanvasSpec canvas;         // aspect (w:h ints, e.g. 9:16) + baseShortSide (720 | 1080 | 2160) -> even px size
  final FrameRate frameRate;
  final BackgroundSpec background; // Solid(color) | BlurOfMain(radius 0..1)
  final int audioSampleRate;       // 48000
}
```

`CanvasSpec.pxSize`: the short side is `baseShortSide`, and the long side is `roundEven(base·ratio)`, so 9:16 at 1080 gives 1080×1920. Every canvas-space quantity in the model is normalized: positions as fractions of the canvas (0 = center) and text sizes in points at a 1080-pixel short side. Changing the canvas therefore never rewrites items.

### 4.3 Tracks, kinds and compositing bands

```dart
enum TrackKind { video, overlay, audio, text, subtitle }
enum AudioRole { original, voice, music, effects }    // ai.md §10.1 needs voice/music
@immutable final class Track {
  final TrackId id; final TrackKind kind; final String name;
  final bool isMain;                                   // exactly one: the first video track
  final bool locked, hidden, muted, solo;
  final AudioRole? audioRole;                          // audio tracks (default: music for picked audio, voice for recordings)
  final SubtitleTrackData? subtitle;                   // subtitle tracks only (§4.9)
  final List<TimelineItem> items;                      // sorted by start; non-overlapping; unmodifiable
  final List<Transition> transitions;                  // sorted by cut time (video/overlay tracks)
  final int changedAt;                                 // revision stamp of last change (UI tile invalidation); unique
}
```

**Bands (z-order, bottom to top):** `video` (the main track is the lowest, and extra video tracks stack above it), then `overlay`, `text`, `subtitle`. Audio tracks have no z. The canonical `tracks` list is grouped `[video…, overlay…, text…, subtitle…, audio…]`. Inside a band, a later track is higher. **The UI displays visual lanes in reverse z order, top to bottom.** That puts extra video lanes *above* the main lane, which differs from ux.md §8.3 (§17).
Because text and subtitles are always above every video and overlay band, the preview can draw them in Flutter over the native texture (decision 9). Putting text behind a picture-in-picture overlay is not supported in v1 [DECISION].

| Kind | Items allowed | Flags that apply | Transitions |
|---|---|---|---|
| video, overlay | `MediaClip` of video, image or still media | visible, mute (if audio), solo, lock | yes |
| audio | `MediaClip` of audio or video media (audio stream only) | mute, solo, lock | no (fades and crossfade via lowering) |
| text | `TextItem` | visible, lock | no |
| subtitle | `SubtitleCue` | visible, lock | no |

Solo affects audio only. When any track is soloed, only soloed tracks are audible. `hidden` removes a track's layers from the plan. `muted` removes its audio. Locked tracks reject every command that targets them (`TrackLocked`).

### 4.4 Items

```dart
sealed class TimelineItem {
  ItemId get id; TimeUs get start; TimeUs get duration; LinkId? get link; String? get label;
  TimeRange get range => TimeRange(start, start + duration);
}
@immutable final class MediaClip extends TimelineItem {
  final MediaId media;
  final TimeUs sourceIn;           // source µs (rendition-independent); 0 for images/stills
  final SpeedSpec speed;           // ConstantSpeed(1) default; ignored for images
  final bool maintainPitch;        // default true
  final bool reversed;             // rendition resolved from pool at compile time (§6.4)
  final int? audioStream;          // null = first audio stream
  final VisualProps? visual;       // null on audio tracks
  final AudioProps audio;
  final bool detachedAudio;        // true after "Extract audio": this clip's own audio is not rendered
  final KeyframeSet keyframes;     // item-local times (§4.11)
  // derived (cached): ClipTimeMap get timeMap; TimeUs get sourceOut;
}
@immutable final class TextItem extends TimelineItem {
  final String text; final TextStyleSpec style; final TextAnimation animation;
  final Transform2D transform;     // position/scale/rotation/opacity; flips ignored
  final KeyframeSet keyframes;
}
@immutable final class SubtitleCue extends TimelineItem {
  final String text;               // '\n' line breaks; inline <i>,<b> only (§11.1)
  final CueOrigin origin;          // manual | imported | generated  (ai.md §10.2)
  final bool editedAfterGeneration;
}
```

**Duration authority.** A media clip stores `(sourceIn, duration, speed)`, and `sourceOut` is derived from the time map. A speed change keeps the *source range* and recomputes `duration = max(1 frame, quantizeNearest(T(sourceRange)))`, which matches the ux.md readout "0:12 → 0:06". A trim sets `duration` (or `start` and `sourceIn`) and is validated with `sourceOut ≤ probe.duration`. Images, stills, text and cues may have any duration of at least one frame.

### 4.5 Speed and the clip time map

```dart
sealed class SpeedSpec {}
final class ConstantSpeed extends SpeedSpec { final double rate; }            // [0.1, 10]; presets 0.25…4
final class SpeedRamp extends SpeedSpec {                                     // speed vs normalized SOURCE position
  final List<SpeedPoint> points;  // 2..16; x strictly increasing, x0 = 0, xn = 1; y in [0.1, 10]
  final String? presetId;         // montage | hero | bullet | jumpCut | flashIn | flashOut | null (custom)
}
final class ClipTimeMap {         // built from (start, duration, sourceIn, speed, reversed, probe.duration)
  TimeUs toSource(TimeUs t);      // timeline -> source µs (clamped to [sourceIn, sourceOut − 1])
  TimeUs? timelineTimeOf(TimeUs s);   // source -> timeline; null if trimmed away (ai.md §10.1)
  TimeRange get sourceRange;
  double speedAt(TimeUs t);
  List<MapSegment> lower({required int maxErrorUs});  // piecewise-linear for the plan (§12.3)
}
```

The ramp math is closed-form. Let L be the source length and let v be linear on each segment [x0, x1] with slope b. The time spent in a segment is `(L/b)·ln(v1/v0)`, or `L·Δx/v0` when b = 0. The inverse is `x(τ) = x0 + v0·(e^{bτ/L} − 1)/b`. Both directions are exact in double precision and are then quantized. For `reversed`, the map runs from `sourceOut` down to `sourceIn`, so the same functions apply with `s' = sourceIn + sourceOut − s`. A ramp stays attached to content: trimming crops and renormalizes it (`SpeedRamp.crop(a, b)`), and extending past the original range holds the edge speed.

### 4.6 Visual properties, effects, color, LUT, chroma, mask

```dart
@immutable final class VisualProps {
  final Transform2D transform; final FitMode fit;          // fit | fill | stretch (base size before transform)
  final CropRect crop;                                     // normalized l,t,r,b in display-oriented source; default full
  final ColorAdjust adjust; final DetailFx detail; final LookRef? look;
  final ChromaKey chroma; final MaskSpec mask;
}
@immutable final class Transform2D { final Vec2 position;  // canvas fractions, 0 = center, [-2, 2]
  final double scale /*[0.01, 8], 1 = fit base*/; final double rotationDeg /*[-360, 360], clockwise*/;
  final bool flipH, flipV; final double opacity /*[0, 1]*/; }
@immutable final class ColorAdjust { final double exposure, brightness, contrast, highlights, shadows,
  saturation, temperature, tint; }                         // each [-1, 1], 0 neutral (UI shows ×100)
@immutable final class DetailFx { final double sharpness, blur, vignette; }   // [0, 1]
sealed class LookRef { final double intensity; }           // [0, 1]
final class BuiltinLook extends LookRef { final String presetId; }            // 12 bundled .vlut looks
final class ImportedLut extends LookRef { final MediaId lut; }                // pool asset of kind lut
@immutable final class ChromaKey { final bool enabled; final int color /*0xRRGGBB*/;
  final double similarity /*0.4*/, smoothness /*0.1*/, spill /*0.3*/; }
@immutable final class MaskSpec { final MaskShape shape;  // none | rectangle | ellipse
  final Vec2 center /*item-local normalized*/; final Vec2 size; final double rotationDeg, cornerRadius,
  feather /*[0,1]*/, opacity /*[0,1]*/; final bool invert; }
```

**Single source for Adjust.** The owner lists Brightness…Tint under both "Video Effects" and "Color & LUT". They are one `ColorAdjust`, as in ux.md §10.0. "Color presets" are bundled LUTs (`BuiltinLook`), so presets and imported LUTs share one pipeline and one intensity control.

**Canonical effect order** (both engines implement it, and parity is tested in the engine docs): crop → chroma key (on source colors) → exposure → temperature/tint → contrast/brightness → highlights/shadows → saturation → look (LUT, mixed by intensity) → sharpness → blur → vignette → mask (alpha) → transform → opacity → premultiplied source-over composite. The reference formulas are published in `schema/effects_reference.md` (DOM-29). They are written as GLSL-like pseudocode in Rec.709 gamma space. The engine docs own the shader code. The golden-frame parity tolerance is ΔE2000 ≤ 2.

### 4.7 Audio

```dart
@immutable final class AudioProps { final double volume;  // linear gain [0, 2], 1 = 0 dB, keyframable
  final bool muted; final TimeUs fadeIn, fadeOut; }        // fades ≤ duration/2 each, on frame grid
```

Background music is an audio track with `audioRole: music`. Voice recordings get `voice`. Audio extracted from video gets `original`. A/V sync works because a video clip's audio and its extracted partner share one `ClipTimeMap` and one `LinkId` (§6.3).

### 4.8 Text

```dart
@immutable final class TextStyleSpec {
  final String fontFamily;                 // FontCatalog id (ux.md Q4); unknown -> 'Figtree'
  final double fontSizePt;                 // [8, 200] at 1080 short side
  final bool bold, italic; final TextAlignH align;            // left | center | right
  final int color /*ARGB*/; final double letterSpacing /*em/100, [-20, 100]*/; final double lineHeight /*[0.6, 3]*/;
  final double maxWidth;                   // canvas-width fraction, default 0.9 (wrap width)
  final BoxStyle? background;              // color, opacity, paddingPt, cornerRadiusPt
  final StrokeStyle? stroke;               // color, widthPt [0, 20]
  final ShadowStyle? shadow;               // color, opacity, blurPt [0, 40], distancePt [0, 40], angleDeg
}
@immutable final class TextAnimation {
  final TextInAnim inKind;  final TimeUs inDuration;    // none | fade | slide(dir) | scale | typewriter
  final TextOutAnim outKind; final TimeUs outDuration;  // none | fade | slide(dir) | scale
}
```

`evaluateTextAnimation(item, t, canvas) → TextAnimState { opacityMul, offsetPx, scaleMul, revealGraphemes? }` is a pure function in `eval/`. The Flutter preview overlay and the plan compiler call **the same function**. Slide moves 10% of the canvas dimension combined with a fade. Easing is ease-out cubic sampled at 6 linear segments. Typewriter reveals `floor(n·p)` grapheme clusters (`package:characters`). It is "in" only, and layout is computed on the full text so lines don't reflow while typing.

### 4.9 Subtitle tracks

```dart
@immutable final class SubtitleTrackData {
  final String? language;              // BCP-47
  final SubtitleStyle style;           // font, sizePt, bold/italic, color, background box, outline, shadow,
                                       // maxLines 1..3, maxWidth fraction, align
  final SubtitlePosition position;     // bottom | top | custom(yFraction); safe margin default 0.06
  final bool burnIn;                   // default for the export sheet's per-track switch
  final CaptionProvenance? provenance; // ai.md §10.2, adopted verbatim (generator, model, language, segmentation,
                                       // scope, transcriptKeys, generatedAt, schema)
}
```

Cues on one track never overlap, and they are sorted. A cue's text is non-empty after trimming. Setting the text to empty is rejected with `EmptyText`, and the UI offers Delete instead.

### 4.10 Transitions, markers, links

```dart
@immutable final class Transition { final TransitionId id; final ItemId left, right;   // left.end == right.start
  final TransitionKind kind;     // fade | crossDissolve | dipToBlack | dipToWhite | slide | wipe | zoom
  final int durationFrames;      // region [cut − ⌊n/2⌋f, cut + ⌈n/2⌉f)
  final TransitionDirection? direction; }                  // l|r|u|d for slide/wipe; in|out for zoom
@immutable final class Marker { final MarkerId id; final TimeUs time; final String name; final int colorIndex; }
```

`TransitionRef` = `(TrackId, left, right)`, as ux.md §2.1 needs. `Fade` means the outgoing clip fades to the canvas background and the incoming clip fades in from it, with no overlap. `crossDissolve`, `slide`, `wipe` and `zoom` need **handles** (§6.5). `LinkId` groups items that move, split, delete and duplicate together (extracted audio, freeze-frame partners). Selection expands across a link unless the user has unlinked the items.

### 4.11 Keyframes and property keys

```dart
final class PropertyKey<T> {           // registry in property_registry.dart; ids are stable JSON keys
  final String id;                     // 'transform.position', 'adjust.exposure', 'audio.volume', 'mask.feather'…
  final String displayName, unit;      // unit: '%', '°', 'dB', ''
  final double min, max, step; final T defaultValue; final double displayScale;   // e.g. ×100 for %
  final bool keyframable; final int channels;   // 2 for Vec2 (position, mask.center, mask.size)
  final Set<ItemKindTag> appliesTo;
  T read(TimelineItem item); TimelineItem write(TimelineItem item, T value);      // static value accessors
}
@immutable final class Keyframe { final TimeUs t; final double v; }      // t item-local, on grid
@immutable final class KeyframeTrack { final List<Keyframe> keys; }      // sorted, unique t, ≥ 1 key
@immutable final class KeyframeSet { final Map<String, KeyframeTrack> byChannel; }  // 'transform.position.x' …
final class KeyframeRef { final ItemId item; final String property; final TimeUs t; }  // ux.md §2.1
```

* **Keyframable in v1:** position, scale, rotation, opacity, volume, the 8 adjust parameters plus sharpness, blur and vignette, and the mask's center, size, rotation, feather and opacity. **Not keyframable:** chroma, look intensity, crop, flips, text style and transition parameters.
* **Interpolation** is linear only. A value is held before the first key and after the last. Rotation interpolates linearly in degrees, with no shortest-path wrapping. A Vec2 key writes both channels at the same `t`. `MoveKeyframe` and `RemoveKeyframe` act on both.
* **Times are item-local and stay attached to content.** A start trim of Δ shifts keys by −Δ. A speed change scales keys by `oldDuration/newDuration`. A split partitions keys and inserts boundary keys holding the interpolated value at the cut. Keys outside `[0, duration)` are **kept**, so un-trimming restores them, and evaluation ignores them.
* `evaluate<T>(item, key, TimeUs t)` returns the keyframed value when a track exists, otherwise the static value (ux.md §2.1).

### 4.12 Media pool

```dart
@immutable final class MediaPool { final Map<MediaId, MediaAsset> assets; }    // insertion-ordered
@immutable final class MediaAsset {
  final MediaId id; final MediaKind kind;          // video | audio | image | lut | still | recording
  final String displayName;
  final MediaLocator locator; final MediaOwnership ownership;    // external | managedCopy | projectOwned
  final MediaFingerprint fingerprint; final MediaProbe probe;
  final MediaOrigin origin;                         // photos | files | library | player | recorded | imported | derived
  final DerivedSpec? derived;                       // reversed(media, range) | still(media, sourceTime)
  final AssetStatus status;                         // ready | pending(jobId) | failed(reason)
  final ProxyState proxy;                           // none | pending | ready(height) | failed
  final DateTime addedAt;
}
sealed class MediaLocator {}
final class AppRelativeLocator extends MediaLocator { final AppRoot root; final String relPath; } // documents|support|cache
final class FileLocator extends MediaLocator { final String path; }                // desktop / external absolute
final class ContentUriLocator extends MediaLocator { final String uri; }           // Android, persisted read grant
final class BookmarkLocator extends MediaLocator { final String bookmarkB64; final String lastKnownPath; } // iOS
@immutable final class MediaFingerprint { final int sizeBytes; final String quickHash; // sha1(head64K+tail64K+':'+size)
  final int? modifiedMs; final TimeUs duration; }
@immutable final class MediaProbe { final TimeUs duration; final bool hasVideo, hasAudio;
  final int? width, height;            // DISPLAY size (rotation applied)
  final int rotation; final FrameRate? nominalFrameRate; final bool variableFrameRate;
  final String? container, videoCodec, audioCodec; final int audioStreams; final int? channels, sampleRate;
  final ColorTransfer transfer;        // sdr | hlg | pq  (iPhone HDR video is HLG; engines tone-map to SDR)
  final int? bitDepth; }
```

`ProjectSummary`, `LoadedProject`, `RecoverableSession`, `ImportOutcome`, `RelinkCheck` and `MediaAvailabilityReport` are the persistence types from ux.md §2.2, defined in `store/` (§9 and §10).

---

## 5. Invariants and validation

`Validator.check(Timeline t, MediaPool p, {Set<TrackId>? only}) → List<Violation>` checks the following:

1. **I1.** Every item `start` and `duration`, keyframe `t` (relative to the item's start), marker time and transition boundary is on the frame grid. `duration ≥ 1 frame` and `start ≥ 0`. The project is at most 24 h long.
2. **I2.** Items within a track are sorted by `start` and do not overlap. Ids are unique across the project.
3. **I3.** Item kind is compatible with track kind (§4.3). Exactly one `isMain` track exists, it is the first video track, and the band order holds.
4. **I4.** A `MediaClip.media` exists in the pool with a compatible kind. `0 ≤ sourceIn` and `sourceOut ≤ probe.duration` for time-based media. Speed and ramp bounds hold. Images and stills ignore speed and reverse.
5. **I5.** Each transition references adjacent touching items on its own track, `durationFrames ≤ maxFrames(left, right)` (§6.5), and at most one transition exists per cut.
6. **I6.** Keyframe tracks are sorted, unique, non-empty, and their values are within `PropertyKey` bounds. Only keyframable properties have tracks.
7. **I7.** Every link group has at least 2 existing members, and members sit on different tracks.
8. **I8.** Subtitle cue text is non-empty. `SubtitleTrackData` exists exactly on subtitle tracks.
9. **I9.** Canvas px dimensions are even and ≥ 16. The frame rate is supported. Fades fit (`fadeIn + fadeOut ≤ duration`).

**Where validation runs:**
* **After every command:** only the changed tracks are checked, at O(changed). A violation turns the outcome into `InternalInconsistency(violations)`. The project is unchanged and the violation is logged, so a bug can never corrupt a document.
* **After decode:** the whole project is checked, followed by `repair()`, which returns `ProjectOpenWarning`s instead of refusing to open:
  * overlaps go to new lanes
  * off-grid edges are requantized
  * dangling media references become `missing` placeholder assets
  * invalid transitions are dropped
  * out-of-range values are clamped
* **In tests and debug builds:** the full validator runs after every command, including under the fuzzer (DOM-19).

---
## 6. Editing operations

### 6.1 Command framework

```dart
sealed class EditCommand { const EditCommand(); String get label; }      // library ops/edit_command.dart + parts
final class EditContext { final IdGenerator ids; final MediaPool pool; final DateTime now; final EditPolicy policy; }
final class EditPolicy { final OverlapPolicy overlap /*newLane*/; final TimeUs defaultImageUs /*3 s*/;
  final TimeUs defaultTextUs /*3 s*/; final TimeUs defaultCueUs /*2 s*/; }
// internal: CommandResult run(Timeline t, EditContext c)
final class EditOutcome {                          // public result of EditSession.apply
  final EditProject project; final Set<ItemId> affected; final Set<TrackId> changedTracks;
  final Set<TrackId> createdTracks; final SelectionHint? selection; final List<EditNotice> notices;
  final EditRejection? rejection; final bool noop; }    // noop: identical result -> no history entry
final class EditPreview {                          // dryRun: positions for ghosts (ux.md §8.9)
  final Map<ItemId, Placement> placements;         // (trackId | NewTrack(kind, index), range)
  final List<NewTrack> createsTracks; final TimeRange? clampedTo; final EditRejection? rejection; }
sealed class EditRejection {}   // TrackLocked(track) · ItemNotFound · WouldOverlap(track, range) ·
  // OutOfSourceRange(maxEnd) · BelowMinDuration · NothingAtTime · UnsupportedForKind(kind) ·
  // IncompatibleTrack · NotAdjacent · TransitionTooLong(maxFrames) · KeyframeExists(t) · EmptyText ·
  // NoRoom · RippleBlockedByLinkedItem(item) · LimitExceeded(what, limit) · MediaUnavailable(media) ·
  // CannotDeleteMainTrack · InvalidValue(property) · InternalInconsistency(violations)
EditOutcome applyCommand(EditProject p, EditCommand c, EditContext ctx);  // ux.md §2.1
EditPreview dryRun(EditProject p, EditCommand c, EditContext ctx);         // same code path, diffed
```

`CompositeCommand(label, List<EditCommand>)` applies its children in sequence and is atomic: if any child is rejected, the whole command is rejected. Apply-to-all, Cut (copy plus delete), Freeze and the AI caption commands are built from it. A command that produces an `identical` timeline returns `noop`.

**Gestures clamp instead of rejecting.** Trim, move and cue-range commands accept `clamp: true`. They then return the nearest valid result and set `EditPreview.clampedTo`. Without the flag, they return the rejection.

### 6.2 Command catalog

| Command | Parameters | Semantics (non-ripple / ripple) | Main rejections |
|---|---|---|---|
| `InsertMedia` | media ids, track?, at, `InsertMode` auto/ripple/overwrite/newLane | Builds clips (full media; images 3 s) back to back. *Ripple*: `at` snaps to the nearest cut of the item under it, then later items on the lane shift right by the inserted length. *Auto*: ripple if ripple mode is on, else a free lane | IncompatibleTrack, MediaUnavailable |
| `MoveItems` | ids, delta, toTrack?, ripple | Moves the selection, keeping relative offsets. Occupied space → nearest free lane of the same kind (policy). *Ripple*: close the gaps at the source, then ripple-insert at the target | TrackLocked, IncompatibleTrack, RippleBlockedByLinkedItem |
| `TrimItem` | id, edge, newTime, ripple, clamp | End edge: set duration. Start edge: set start and `sourceIn = map⁻¹(newStart)`, and shift keys by −Δ. Never overlaps a neighbor. *Ripple*: following items shift by Δ. A ripple head trim keeps `start` fixed and pulls the rest left | BelowMinDuration, OutOfSourceRange |
| `SplitItems` | ids (empty = main lane at t), at | Each item containing `at` strictly becomes two. Split is defined through `ClipTimeMap`, so it is correct for ramped and reversed clips. Keys partition with boundary keys. Left keeps fade-in and the left transition. Right keeps fade-out and the right transition. Text: in-anim on the left, out-anim on the right. Linked partners split too (right halves get a new LinkId) | NothingAtTime |
| `DeleteItems` | ids, ripple | Removes items and their transitions. *Ripple*: merges removed intervals per lane and shifts later items left | TrackLocked |
| `DeleteGap` | GapRef(track, range) | Shifts that lane's items after the gap left by its length (plus linked partners) | RippleBlockedByLinkedItem |
| `DuplicateItems` | ids | Copies with new ids, placed right after the selection's end on the same lane (ripple if occupied and ripple is on, else a free lane) | NoRoom |
| `PasteItems` | `ClipboardPayload`, at, preferTrack? | Items keep relative offsets and lane kinds. Missing media is added to the pool as a sticky change. Uses the selected lane if compatible, else the first free lane of the kind | IncompatibleTrack |
| `ReplaceMedia` | item, media | Keeps the range, effects and keys. `sourceIn` is kept if valid, else 0. Shortens to fit (notice `trimmedToFit`). Video ↔ video/image; audio ↔ audio | UnsupportedForKind |
| `ExtractAudio` | item | New `MediaClip` on a free audio lane (same media, map and audio props; volume keys move). Sets the source `detachedAudio = true` and links both | UnsupportedForKind (no audio) |
| `FreezeFrame` | item, at, durationUs, stillMedia | Splits at `at` and inserts a still clip of `durationUs` (ripple on that lane plus linked partners). `stillMedia` is a pending derived asset (§6.4) | NothingAtTime |
| `SetReversed` | item, bool | Flips the flag. The rendition is resolved at compile time (§6.4) | UnsupportedForKind (image) |
| `SetSpeed` | item, SpeedSpec, maintainPitch | Keeps the source range, recomputes duration and scales keys. Following items ripple only when ripple mode is on, else growth clamps against the next item (`clampedTo`) | OutOfSourceRange, InvalidValue |
| `SetProperty<T>` | item(s), key, value, at? | No keyframes: sets the static value. Keyframed: upserts a key at the frame-quantized `at − start`. Applied to several items, it is one entry | InvalidValue, UnsupportedForKind |
| `SetVisual` / `SetAudio` / `SetLook` / `SetChroma` / `SetMask` / `SetCrop` / `ResetTransform` | item(s), value | Whole-struct setters for panels. Reset clears transform keys too | UnsupportedForKind |
| `AddKeyframe` / `RemoveKeyframe` / `MoveKeyframe` / `SetKeyframeValue` / `ClearKeyframes` | KeyframeRef, … | Vec2 properties act on both channels | KeyframeExists, InvalidValue |
| `AddText` / `SetText` / `SetTextStyle` / `SetTextAnimation` | … | Text goes on the top free text lane (created if needed) | EmptyText |
| `AddCue` / `SetCueText` / `SetCueRange` / `SplitCue` / `MergeCues` / `ImportSubtitles` | … | §6.7 | NoRoom, EmptyText, NotAdjacent |
| `SetSubtitleStyle` / `SetSubtitlePosition` / `SetBurnIn` / `SetSubtitleLanguage` | track, value | Track-wide | |
| `AddGeneratedCaptionTrack` / `ReplaceGeneratedCaptions` | ai.md §10.2 | One entry. Fresh ids. `origin = generated`. Replace honors the range | TrackLocked |
| `SetTransition` / `ApplyTransitionToAll` | TransitionRef, spec? | null removes. Duration clamped to `maxFrames`. Apply-to-all covers every cut on a lane | NotAdjacent, TransitionTooLong |
| `AddTrack` / `DeleteTrack` / `MoveTrack` / `RenameTrack` / `SetTrackFlags` / `SetAudioRole` | … | Moves stay within the band. Main can't be deleted or moved | CannotDeleteMainTrack |
| `AddMarker` / `UpdateMarker` / `DeleteMarker` | … | Times quantized | |
| `LinkItems` / `UnlinkItems` | ids | | |
| `SetCanvas` / `SetFrameRate` / `SetBackground` | … | `SetFrameRate` runs `requantize` (§6.6) | |

*Not commands:* selection, zoom, scroll, playhead and panels (UI state), plus import, relink, proxies and job results (pool changes, §7.2).

### 6.3 Ripple, overlap and links

* **Ripple scope:** the lanes of the edited items, plus the lanes of their linked partners. A shift on lane L from time T moves every item on L with `start ≥ T`. Their linked partners move by the same delta. If a partner would then overlap something on its own lane, the edit is rejected with `RippleBlockedByLinkedItem`. Sync-locking every lane is deferred [DECISION]. ai.md and ux.md both render whatever `dryRun` returns.
* **Overlap resolution (`OverlapPolicy.newLane`):** the moved or inserted group per source lane tries its target lane, then the next lanes upward in the same band, then a new lane at the top of the band. The result shows up in `EditPreview.createsTracks`.
* **Main lane:** gaps are allowed and can be selected (`DeleteGap`). With ripple mode on, an insert or move on the main lane snaps to the nearest cut (magnetic behavior).
* **Selection expansion:** `SelectionRules.expand(project, ids)` adds link partners and drops items on locked tracks. UX calls it before building commands.

### 6.4 Derived media (reverse, freeze frame)

* **Reverse.** `SetReversed` only flips the flag. The compiler then looks up a pool asset with `derived = reversed(media, R)` and `status = ready`, where R covers the clip's source range. If it finds one, the layer uses the rendition with a mirrored map: rendition time `r = R.end − s` (the rendition starts at r = 0 for s = R.end), which increases as playback runs backward through the source. If not, the clip is listed in `PlanRequirements.pendingReverse` (§12.6). The session (UX) starts `MediaJobs.reverse(media, range ± 2 s handles)` and adds the pending asset as a sticky pool change. Preview plays forward until the rendition is ready. Export is blocked. Undo leaves the rendition in the pool, and GC reclaims it later.
* **Freeze frame.** The command takes a `stillMedia` id that the session created as a pending `still` asset (sticky add) before applying. The engine job fills in the locator and sets `ready`. Until then, the compiler emits a placeholder layer over the original video with a constant map (`s0 == s1` = the freeze time, `holdFrame: true`). If the engine reports that it can't hold frames, the placeholder is a solid neutral layer. Export is blocked until the still is ready.

### 6.5 Transition limits

`maxFrames(left, right, kind)` returns the following:
* **All kinds:** at most `2·min(leftAvail, rightAvail)`, because each half of the region lies inside its own clip. `avail` is the clip's duration minus the half of any transition at its other edge.
* **Overlap kinds** (crossDissolve, slide, wipe, zoom) also need handles, so they are additionally limited to `2·min(leftHandle, rightHandle)`.
  * `leftHandle` is the media left after `left.sourceOut`, divided by the speed at the end.
  * `rightHandle` is `right.sourceIn` divided by the speed at the start (mirrored for reversed clips).
  * Images and stills have infinite handles.
* **No-overlap kinds** (fade, dipToBlack, dipToWhite) need only the first bound.

The result is exposed as `TransitionLimits.of(project, ref)`, which ux.md §10.12 reads as `maxAllowed`. Any command that breaks adjacency (move, gap-creating trim, delete) removes the transition, and undo restores it. A roll that moves the cut but keeps the clips touching keeps the transition and re-clamps its duration.

### 6.6 Project-level operations

* **`requantize(newRate)`** maps `start` to the nearest frame and duration to the nearest frame count (at least 1). Items keep their order on a lane. When a conflict appears, later items shift right by one frame. Keys, markers and fades are quantized, and transitions are re-clamped. This is property-tested: order is preserved, and every item moves less than one new frame plus any cascade.
* **`SetCanvas`** never rewrites items, because positions are normalized. ux.md shows the "Clips keep their size" toast.

### 6.7 Subtitles

| Operation | Rule |
|---|---|
| `AddCue(track, at, dur=2 s, text)` | Placed in the free space at `at`. If less than 2 s is free, it shrinks to fit (minimum 1 frame). No space at all → `NoRoom` |
| `SetCueRange` | Never overlaps neighbors. With `clamp`, it stops at the neighbor edge |
| `SplitCue(cue, at, textSplit?)` | `textSplit` is a UTF-16 index from the UI cursor. Without one, the split falls on the word boundary nearest the middle (by graphemes). Both halves must be non-empty after trimming |
| `MergeCues(ids)` | The cues must be consecutive on one track. The range is the union. Texts are joined with a space when the result has ≤ 42 graphemes and no `\n`, otherwise with `\n` |
| Text edits on a `generated` cue | Set `editedAfterGeneration = true` (ai.md §10.2 rule 2) |
| `ImportSubtitles(cues, target: newTrack(name, lang) / replace(track))` | Overlapping input cues spill onto a second subtitle track, so nothing is lost. A notice reports the count |

### 6.8 Snapping and clipboard

```dart
final class SnapIndex {                                  // built once per drag; O(n log n)
  static SnapIndex build(EditProject p, {Set<ItemId> exclude, TimeUs? playhead,
      bool markers = true, bool keyframesOf = false /*ItemId*/, bool cues = true});
  SnapHit? nearest(TimeUs t, TimeUs thresholdUs);        // binary search on Int64List; kind: edge|marker|playhead|keyframe
  SnapHit? nearestForRange(TimeRange r, TimeUs thresholdUs); // checks both edges; returns delta
}
final class ClipboardPayload { final int schema; final List<Map<String, Object?>> items;  // codec JSON
  final Map<MediaId, Map<String, Object?>> media; final ProjectId source; final TimeUs anchor; }
ClipboardPayload copyItems(EditProject p, Set<ItemId> ids);     // pure; UX stores it (ux.md §14.4)
```

The UI converts its pixel threshold (8 or 12 px) to time and snaps the *proposed* time before it calls `dryRun`. Commands never snap on their own.

---

## 7. History, transactions and the session

### 7.1 Why snapshots and not inverse commands

| Criterion | Snapshot (chosen) | Inverse command |
|---|---|---|
| Correctness | Exact by construction: restoring a root restores everything | Every command needs a hand-written, separately tested inverse. Bugs show up as corrupted undo |
| Compound edits (apply to all, AI captions, ripple cascades) | Free | Requires composite inverses |
| Memory | Shared structure: an entry costs only the changed lanes' item lists plus changed items (≈ 4–40 KB per typical edit) | Smallest |
| Persisted, collaborative history | Not needed in v1 | Needed for collaboration (out of scope) |

The model is immutable anyway, so snapshots are the simplest correct option.

### 7.2 Session API (pure Dart; `EditorController` in ux.md §16.3 wraps it)

```dart
final class EditSession {
  EditSession(EditProject initial, {IdGenerator? ids, HistoryPolicy policy = const HistoryPolicy()});
  EditProject get project;                         // working copy during a transaction
  HistoryStatus get history;                       // canUndo, canRedo, undoLabel, redoLabel, position
  EditOutcome apply(EditCommand c, {String? coalesceKey, Duration coalesceWindow = const Duration(seconds: 1)});
  EditPreview dryRun(EditCommand c);
  SessionTransaction begin(String label);          // a second begin cancels the first
  HistoryStep? undo(); HistoryStep? redo(); HistoryStep? jump(int steps);   // jump: one combined step
  void applyPoolChange(PoolChange change);         // sticky: AddAssets, UpdateAsset (probe/proxy/status)
  EditOutcome applyPoolEdit(PoolEdit edit);        // undoable: RelinkAssets, RemoveAssets (unused only)
  void updateView(ViewState Function(ViewState) f);// persisted, never in history
  List<String> recentLabels(int max);
  Set<MediaId> retainedMedia();                    // union over history snapshots -> GC guard (§10.5)
}
abstract interface class SessionTransaction { void update(EditCommand c); EditPreview? get preview;
  EditOutcome commit(); void cancel(); bool get isOpen; }
final class HistoryEntry { final String label; final Timeline before, after;
  final PoolDelta? poolDelta; final Set<ItemId> affected; final DateTime at; final int approxBytes; }
final class HistoryPolicy { final int maxEntries /*200*/; final int maxApproxBytes /*48 MB*/; }
```

* **Transactions** match ux.md §16.4. `update` applies its command to the base captured at `begin`, never on top of the previous update. `commit` adds exactly one entry and is a no-op when nothing changed. `cancel` restores the base.
* **Coalescing.** If an apply has the same `coalesceKey` as the top entry within the window (text typing: `'text:<id>'`), it replaces that entry's `after` instead of pushing a new one.
* **Pool and undo.** Undo and redo swap `Timeline` only. If an entry has a `PoolDelta` (relink, remove), its before or after asset values are applied to the *current* pool. Imports never get a delta, so undo never empties the bin. Removal is allowed only for media unused by the current timeline, and its delta keeps every snapshot consistent. Invariant I4 holds at every history position.
* **Limits.** Old entries are dropped when either limit is exceeded. `approxBytes` counts new item lists at 8 B per slot and new items at about 300 B each. History is in memory only and is not persisted.
* **Revisions are stamps, not counters.** The session owns one monotonic counter. At open it is initialized to `max(persisted revision, max changedAt) + 1`.
  * `apply`, `undo` and `redo` each set `Timeline.revision` to the next stamp. Undo restores the snapshot's tracks, markers and settings `identical`ly and only re-stamps the root (`copyWith(revision:)`).
  * Changed tracks get `changedAt = stamp`. A restored track keeps its old stamp, and that stamp was never reused, so UI tile caches and engine plan revisions can never collide after an undo followed by a new edit.
  * Pool and view changes bump only `EditProject.docRevision`.
  * `ProjectMeta.editCount` increments per committed entry. It lives outside the snapshot, so undo does not decrement it ("touched" stays touched).

---

## 8. Evaluation and geometry (pure, used by UI, compiler and AI)

```dart
T evaluate<T>(TimelineItem item, PropertyKey<T> key, TimeUs t);            // §4.11
ItemBox? boxAt(EditProject p, ItemId id, TimeUs t, {TextMetricsProvider? text}); // ux.md §7.2; canvas px
final class ItemBox { final Offset2 center; final Size2 size; final double rotationDeg; final bool flipH, flipV; }
abstract interface class TextMetricsProvider {                               // implemented in danaview_editor with ui.Paragraph
  Size2 measure(TextLayoutSpec spec);                                       // canvas px, incl. background padding
}
TextLayoutSpec textLayoutSpecOf(TextItem item, CanvasSpec c);               // renderer-neutral, §12.5
TextLayoutSpec cueLayoutSpecOf(SubtitleCue cue, SubtitleTrackData d, CanvasSpec c);
TextAnimState evaluateTextAnimation(TextItem item, TimeUs t, CanvasSpec c); // §4.8
Size2 baseSize(MediaProbe probe, CropRect crop, FitMode fit, Size2 canvas);  // shared by boxAt AND compiler
```

`boxAt` composes these steps: the display-oriented source size, then crop, then `baseSize` for the fit mode, then flips, scale, rotation and the translation to `canvasCenter + position·canvas`. It evaluates keyframes and the text animation at `t`. The compiler calls the same `baseSize` and transform code, so preview handles and rendered output agree by construction. This is the parity test in DOM-07.

---
## 9. Project storage

### 9.1 Roots and bundle layout

```dart
final class StoreRoots {                 // built in lib/main.dart from AppStorage (danaview_data); plain strings
  final String support;                  // <ApplicationSupport> (iOS Library/Application Support; Android filesDir)
  final String cache;                    // <Caches | cacheDir> (purgeable)
  final String documents;                // <Documents> (library originals; read-only to the editor)
  String get editorSupport => '$support/danaview/editor';  String get editorCache => '$cache/danaview/editor';
}
```

```
<support>/danaview/editor/
  projects/<projectId>/
    project.dnproj            main document (header line + body line)
    project.dnproj.bak        previous good main (rotated on every main write)
    journal/a.dnproj b.dnproj autosave slots (alternating); recovered-<ts>.dnproj (kept after "Open last saved")
    meta.json                 summary for the Projects list (rebuildable from project.dnproj)
    refs.json                 managed paths, derived specs, URI grants, retained (in-history) media: GC input
    poster.jpg                project thumbnail (engine renders on exit save)
    assets/luts/<id>.cube + <id>.vlut   assets/recordings/<id>.m4a   assets/stills/<id>.png
    backups/pre-migration-s<N>.dnproj
  media/<hh>/<quickHash>/<sanitized name>      managed copies, shared by projects (content-addressed)
  derived/<specHash>.mp4                       reversed renditions, shared, regenerable
  trash/<projectId>-<ts>/                      staged deletes
<cache>/danaview/editor/
  thumbs/<quickHash>/…  waveforms/<quickHash>-<stream>.peaks  proxies/<quickHash>-<h>.mp4   (engine-owned formats)
  sprites/<spriteKey>.png  looks/<presetId>.vlut  renders/<jobId>/  subtitles-export/  tmp/
```

* **Why Application Support.** `Documents` is the scanned "On This Device" library (ux.md §1), and Caches is purgeable. Project JSON, recordings, stills and LUTs are small and user-authored, so they are backed up.
* **Excluded from backup:** `media/` and `derived/`, which are large and either re-importable or regenerable.
  * **iOS:** `NSURLIsExcludedFromBackupKey` set on these directories through `MediaAccessPort.excludeFromBackup`. Setting it on a directory excludes its contents [VERIFY].
  * **Android:** `res/xml/data_extraction_rules.xml` (API 31+) and `backup_rules.xml` (API ≤ 30) exclude `file/danaview/editor/media/` and `file/danaview/editor/derived/`.
* **After a restore,** projects open with missing media and the relink flow handles it.
* **No global index file.** The Projects list scans `projects/*/meta.json`, which is cheap at 1,000 dirs. A bad or missing `meta.json` is rebuilt from the document in an isolate.

### 9.2 File format and schema

```
{"format":"danaview.editor.project","schema":1,"minReader":1,"app":"1.1.0+3","savedAt":"2026-10-07T10:00:00Z","docRevision":812,"saveId":"sv_…","bodyBytes":48213,"bodySha256":"…"}\n
{"id":"pr_…","meta":{…},"settings":{…},"tracks":[…],"markers":[…],"pool":{…},"view":{…}}\n
```

* **Header line plus body line.** The body's SHA-256 detects torn or truncated writes, which matters because `dart:io` cannot fsync a directory. The header can be read without parsing the body (Projects list, `needsNewerApp`). Hashing runs in the writer isolate.
* **Body conventions:**
  * times are integer µs
  * colors are `"#RRGGBBAA"`
  * doubles use Dart's shortest round-trip form
  * fields equal to their default are omitted
  * keys are written in fixed order, so the output is deterministic and testable
  * items carry `"t":"clip"|"text"|"cue"`
  * ids are strings
  * enums are lower-camel strings
* **Unknown enum values within a supported schema** decode to the default and add a `ProjectOpenWarning`.
* **Versioning:** `schema` increments on every format change, and `minReader` increments only when an older app would misread the file.
  * `schema > supported` and `minReader > supported`: `ProjectHealth.needsNewerApp`, and the project can't be opened (ux.md §5.2).
  * `schema > supported` but `minReader ≤ supported`: opens **read-only** with a banner, because saving would drop unknown fields [DECISION].
* **Example** (abridged clip):

```json
{"t":"clip","id":"it_8Qm2","start":0,"dur":5005000,"media":"md_a1","in":1000000,"speed":{"c":1.5},"pitch":true,
 "visual":{"xf":{"pos":[0.1,0],"s":1.2,"r":0},"fit":"fill","adj":{"exposure":0.12},"look":{"builtin":"teal","i":0.8}},
 "audio":{"vol":0.8,"fadeIn":500500},"kf":{"transform.scale":[[0,1.0],[2002000,1.4]]},"link":"ln_3"}
```

### 9.3 Migrations

```dart
abstract interface class Migration { int get from; Map<String, Object?> up(Map<String, Object?> body, MigrationLog log); }
final class Migrations { static const current = 1; static final List<Migration> chain = [...]; // s1 -> s2 -> …
  static MigrationResult run(Map<String, Object?> body, int fromSchema); }   // pure, runs in the decode isolate
```

* Migrations work on **raw JSON maps**, not on model classes. Old model classes never need to be kept, and the decoder knows only the current schema.
* Before the first write after a migration, the original main file is copied to `backups/pre-migration-s<N>.dnproj`. Opening a project never writes anything. A migrated document is written at the first save, and re-opening before that migrates again (migrations are idempotent).
* `LoadedProject.migratedFrom = MigrationInfo(fromSchema, toSchema, notes)` drives the ux.md toast.
* **Tests:** every schema keeps fixtures under `test/fixtures/projects/s<N>/`. Every fixture must migrate, validate, re-encode and decode back to an equal model. v1 ships the framework plus a test-only `s0 → s1` migration so the path is exercised. ai.md's additive `provenance` and `origin` fields are **already in s1**, so no bump is needed.

### 9.4 Atomic writes

`AtomicFile.write(path, header, bodyBytes)` runs in the writer isolate:

1. Write `path.tmp-<rand>` and `flush()` it. This is expected to fsync [VERIFY: dart:io `RandomAccessFile.flush` → fsync on iOS/Android].
2. Rename `path` to `path.bak` (atomic; replaces the old `.bak`).
3. Rename the tmp file to `path`.

**Read order:** `path` if its checksum is valid, otherwise the newest valid of `{path.tmp-*, path.bak}`. If no candidate is valid, the result is `ProjectHealth.corrupt`, and ux.md offers "Restore last good version" when a backup or journal exists.

**Abstraction.** Every filesystem call goes through `StoreFs`, an interface with `LocalStoreFs` and a `FaultInjectingFs` for tests. The fake can fail or "crash" after any step. DOM-24 runs every crash point and asserts that a valid document is always recoverable.

### 9.5 Saving, autosave, journal and recovery

| Trigger | Writes | Notes |
|---|---|---|
| Commit, pool change or view change | Autosave: next journal slot (a/b) | Debounced **2 s idle**, forced at **10 s** during continuous editing. Skipped while a transaction is open |
| `saveNow(manual)` (⌘S, Project › Save) | Main + meta + refs. Journal truncated | `SaveReceipt(manual: true)`. Clears the `Recovered` badge |
| App `hidden`/`paused`, editor `close()` | Main + meta + refs (+ poster via engine). Journal truncated | `close()` waits up to 3 s (ux.md §4.7) |

**Encoding.** Encoding is incremental on the main isolate. `FragmentCache` is an `Expando<String>` keyed by item, track and asset identity, so only changed objects are re-encoded. Thanks to structural sharing, a 2,000-item project re-encodes in ≤ 3 ms after a typical edit. Only the resulting string is sent to a long-lived **writer isolate**, which hashes and writes. Every save request for a project goes through one serial queue per project. A request that arrives while a write is running replaces the pending one (latest wins).

**Recovery.** At app start, `recoverable()` lists projects whose newest valid journal slot has `docRevision > main.docRevision` and `baseSaveId == main.saveId`. This happens only after a crash, a kill or a failed background save, because normal exits truncate the journal.
* `restore(s)` promotes the journal to main through the atomic path.
* `discard(s)` deletes it.
* Opening a project with a pending recovery returns `LoadedProject.pendingRecovery` (ux.md §13.3). If the user picks "Open last saved", the journal is renamed to `journal/recovered-<ts>.dnproj` and kept until the next successful main save.
* Save failures (disk full, I/O) surface as `SaveStatus.failed(StoreFailure)`. Edits stay in memory, and the next trigger retries.

### 9.6 Repository API (fulfills ux.md §2.2)

```dart
abstract interface class ProjectRepository {
  Stream<List<ProjectSummary>> watchSummaries();          // in-process index; emits after every mutation
  Future<ProjectId> create(NewProjectSpec spec);          // NewProjectSpec.empty(name, canvas?) | .fromMedia(picks, name, initialPlayhead, origin)
  Future<LoadedProject> open(ProjectId id);               // migration + repair + recovery check; registers an open session
  Future<SaveReceipt> save(EditSession s, {required SaveReason reason});   // autosave | manual | exit | background
  void requestAutosave(EditSession s);                    // debounced (§9.5)
  Future<void> flush(ProjectId id);                       // lifecycle: waits for pending writes
  Future<void> close(ProjectId id);
  Future<void> rename(ProjectId id, String name);         // 1–80 chars after trim; open project: via its session
  Future<ProjectId> duplicate(ProjectId id, {String? name});  // "<name> copy", "<name> copy 2"…
  Future<void> delete(ProjectId id);                      // stage to trash/, delete owned files, then GC
  Future<List<RecoverableSession>> recoverable();
  Future<LoadedProject> restore(RecoverableSession s); Future<void> discard(RecoverableSession s);
  Future<ProjectId?> findUntouchedProjectFor(String pathOrUri);   // origin.fromPlayer fingerprint match && editCount == 0
  Future<ProjectStorageReport> storageReport();           // per-project bytesOwned + shared store totals
}
final class ProjectSummary { /* ux.md §2.2 fields */ ProjectId id; String name; DateTime updatedAt; TimeUs duration;
  AspectRatio aspect; String? thumbnailPath; int missingMediaCount; bool hasRecovery; int bytesOwned;
  ProjectHealth health; /* ok | needsNewerApp | readOnlyNewer | corrupt */ }
```

* **`create(fromMedia)`** probes the media (engine), imports it (§10.1), and derives settings from the first video:
  * aspect from the display size, snapped to a standard ratio within 1%, else exact
  * frame rate snapped to the nearest supported rate within 0.5%, capped at 60 (VFR phone video averaging 29.98 → 30000/1001)
  * base short side from the source: ≤ 720 → 720, else 1080. 2160 only when the source is ≥ 2160 and `EditorCapabilities` allows it
  * `initialPlayhead` stored in `view.playhead`, quantized
* **Duplicate** copies `project.dnproj`, `assets/` and `poster.jpg` and rewrites the id, name, `origin` and `createdAt`. Managed media and derived renditions are shared, not copied.
* **Rename** of a closed project rewrites the document atomically.
* **Delete** renames the bundle into `trash/` atomically, then deletes it in the background through `OwnedFileDeleter`, then runs GC (§10.5). ux.md's undo toast delays the call, so the repository never needs to un-delete.
* **Concurrency.** A project can be open in only one session, enforced by an in-process registry. A second `open` returns `ProjectBusy`. Rename and duplicate of an open project go through its session and save queue.

---

## 10. Media management

### 10.1 Import policy (originals are never touched)

| Source (from `EditorEngine.pickMedia` / player) | What the engine hands over | Stored as | Ownership |
|---|---|---|---|
| iOS Photos (`PHPickerViewController`) | Temp file from `loadFileRepresentation`, deleted when the callback returns | Engine moves or copies it into `media/…` **inside the callback** (APFS clone when possible [VERIFY]) | managedCopy |
| iOS Files (document picker, open in place, `asCopy: false`) | Security-scoped URL | `BookmarkLocator` (bookmark created while access is active; no copy) | external |
| Android Photo Picker / SAF `ACTION_OPEN_DOCUMENT` | `content://` URI | `ContentUriLocator` plus `takePersistableUriPermission(READ)` [VERIFY: photo-picker URIs persistable; grant cap 512 on API 30+, 128 before] | external |
| Player "Edit": file under `Documents` (library) | Path | `AppRelativeLocator(documents, rel)` | external |
| Player "Edit": Android incoming-intent cache copy (`cacheDir`) | Path in purgeable cache | **Copied** into `media/…` (the player may still use its copy) | managedCopy |
| Player "Edit": iOS in-place URL | Path, access started by AppDelegate | Engine creates a bookmark through the port | external |
| Desktop (later) | Path | `FileLocator` | external |
| Voice recording, freeze still, LUT import | Engine output / picked `.cube` | `assets/…` in the bundle; LUT copied and normalized (§11.2) | projectOwned |
| Reversed rendition | Engine job output | `derived/<specHash>.mp4` | projectOwned (shared) |

**Moving files.** Only app-owned temp files can be moved, and only into editor roots. This is the same rule as `LibraryStorage`, enforced by `OwnedFileDeleter.canConsume(path)`.
**Dedupe.** Before copying, `quickHash` is checked against the pool and the managed store. A hit reuses the existing copy and deletes the temp file. Re-picking the same video gives the same `MediaId` within a project.
**Grant budget.** When fewer than 32 persistable grants remain, the import falls back to a managed copy and adds a notice.

```dart
abstract interface class MediaPoolService {                          // ux.md §2.2
  Future<List<ImportOutcome>> import(EditSession s, List<PickedMedia> picked, {ImportTarget? target});
  Stream<MediaAvailabilityReport> watchAvailability(EditSession s);   // re-checks on open, resume, relink
  Future<RelinkCheck> checkRelink(EditSession s, MediaId id, PickedMedia candidate);
  Future<EditOutcome> relink(EditSession s, Map<MediaId, PickedMedia> picks);   // one undoable PoolEdit ("Relink media")
  Future<List<RelinkCandidate>> findInSameFolder(EditSession s, PickedMedia anchor);  // path-based locators only
}
abstract interface class MediaAccessPort {                           // engine package implements; Dart default for paths
  Future<ResolvedMedia> resolve(MediaLocator l);     // absolute path or URI usable natively; refreshed bookmark if stale
  Future<MediaStat?> stat(MediaLocator l);           // size, mtime; null = missing; throws AccessLost
  Future<String> quickHash(MediaLocator l);          // same algorithm as MediaIdentityService
  Future<MediaLocator> persist(PickedMediaHandle h); // bookmark / persisted grant
  Future<void> release(MediaLocator l);              // releasePersistableUriPermission
  Future<void> excludeFromBackup(String dirPath);
  Future<int> remainingGrantBudget();
}
```

### 10.2 Fingerprints

`MediaFingerprint.quickHash` uses the `MediaIdentityService` algorithm (tested equal on fixtures), so it is computed in O(128 KB) whatever the file size. It serves four purposes:
* the dedupe and managed-store key
* the thumbnail, waveform and proxy cache key, so caches survive relink and are shared across projects
* ai.md's `mediaFingerprint`
* relink verification

Size is part of the hash. Two different files with identical size, first 64 KB and last 64 KB are theoretically possible, so relink also compares probe duration and dimensions. That residual risk is accepted.

### 10.3 Missing media detection

`watchAvailability` stats every locator through the port when a project opens, on app resume, and after a relink. The full hash is recomputed only when size or mtime changed.

| State | Meaning | UI (ux.md §13) |
|---|---|---|
| `available` | Found, and size/mtime match (or the hash matches) | n/a |
| `missing` | Path doesn't exist, or the URI fails to resolve | Badge, banner, relink |
| `accessLost` | Grant revoked, bookmark unresolvable, or permission denied | Relink ("Danaview lost access to this file") |
| `changed` | Found, but the hash differs (the file was edited elsewhere) | Banner offering "Use updated file" (accept) or Relink |
| `derivedMissing` | A regenerable rendition, still or proxy is gone | Not shown as missing; the job is requeued |

Offline clips stay on the timeline unchanged. The compiler emits placeholder layers for them (§12.6), and export is blocked.

### 10.4 Relink

`checkRelink` probes the candidate and returns one of these results:
* `match`: the fingerprint is equal, or the duration is within ±100 ms and the kind and dimensions are equal
* `durationMismatch(original, candidate)`: on accept, clips that run past the new end are clamped (notice)
* `differentKind`
* `unsupported(reason)`

`relink` applies one `PoolEdit` (undoable, label "Relink media") that swaps the locator, fingerprint and probe. `findInSameFolder` matches by file name, then by fingerprint, and works only where the folder is readable (desktop, app `Documents`). On iOS document-picker and Android content URIs it returns an empty list. This is a platform limit, and ux.md's "Relink others in the same folder" button is hidden there.

### 10.5 Garbage collection and the deletion guard

* **Mark.** The union of every `projects/*/refs.json` (managed paths, derived spec hashes, persisted grants, and the `retained` media of open sessions from `EditSession.retainedMedia()`), plus anything an in-flight import or job currently holds.
* **Sweep.** Files under `media/` and `derived/` that are unreferenced and older than 24 h are deleted. Unreferenced URI grants are released.
* **When.** 30 s after app start (idle), after a project delete, and from Settings › Storage. Never while an export runs.
* **`OwnedFileDeleter`** is the **only** delete path in the editor. It resolves symlinks, requires the target to be inside `StoreRoots.editorSupport` or `editorCache` and outside `documents`, and refuses `external` assets. A refused delete throws `OwnershipViolation`, a programming error that is logged and reported in debug. Tests fuzz it with symlinks, `..` segments and case variants.

### 10.6 Proxies and caches

Proxy state lives on the pool asset (`ProxyState`). The proxy file itself sits in the cache, keyed by `quickHash`. A preview plan carries the proxy locator when it is ready, and the engine chooses based on `setUseProxies`. Export plans never carry proxies. The thumbnail, waveform and proxy formats belong to the engines. This area defines only the keys and the folders.

---
## 11. Formats

### 11.1 SRT and WebVTT

```dart
abstract final class SubtitleCodec {
  static SubtitleParseResult parse(Uint8List bytes, {SubtitleFormat? hint});   // run in Isolate.run (ux.md §17.1)
  static String serialize(List<CueData> cues, SubtitleFormat f, {TimeUs offset = 0, bool bom = false});
}
final class SubtitleParseResult { final SubtitleFormat format; final List<CueData> cues;   // CueData = (TimeRange, text)
  final List<ParseIssue> issues;      // (line, kind) — e.g. 'Line 88: the timing isn't valid'
  final int strippedTags; final int ignoredSettings; final String detectedEncoding; }
```

**Decoding** (`text_decoding.dart`):
* A UTF-8, UTF-16LE or UTF-16BE BOM wins.
* Otherwise, without a BOM, a NUL-byte pattern means UTF-16.
* Otherwise strict UTF-8.
* Otherwise Windows-1252, with Latin-1 as the last fallback.
* Line endings `\r\n`, `\r` and `\n` are all accepted.

**SRT parsing** is tolerant:
* the index line is optional or may be wrong
* `HH:MM:SS,mmm` accepts `.` as separator, 1–3 digit fractions and more than 99 hours
* trailing coordinates (`X1:…`) are ignored and counted
* blocks are separated by one or more blank lines

**WebVTT parsing:**
* requires a `WEBVTT` header (BOM optional, text after it allowed)
* timestamps are `(hh:)mm:ss.ttt`
* the cue identifier is optional
* `NOTE`, `STYLE` and `REGION` blocks are skipped
* cue settings are ignored (positioning is track-level) and counted
* entities `&amp; &lt; &gt; &nbsp; &lrm; &rlm;` are decoded

**Markup in both formats:**
* `<i>` and `<b>` are kept, normalized and balanced.
* `<u>`, `<font>`, `<c.x>`, `<v Speaker>` and timestamp tags are stripped (text kept), and the count goes to `strippedTags`.
* `{\an8}` ASS-style overrides in SRT are stripped.

**Validation on parse:**
* `end > start` is required. Invalid cues become issues, and the rest still import.
* Times round to µs, then to the project grid on insert. Start rounds to the nearest frame, and end is at least start plus one frame.

**Serialization:**
* times are timeline times plus an optional offset
* rounding is half-up to milliseconds
* SRT: numbering from 1, CRLF line endings
* VTT: `WEBVTT` + blank line, LF line endings
* UTF-8 without BOM (`bom: true` option for legacy players)
* blank lines inside a cue are collapsed, because a blank line ends a cue
* a literal `-->` in the text becomes `->`
* VTT escapes `& < >` outside the kept tags

**Round trips.** `parse(serialize(x)) == x` for the supported subset, property-tested. A corpus of real files (BOMs, CJK, RTL, CRLF/LF, malformed) lives under `test/fixtures/{srt,vtt}`.

### 11.2 `.cube` LUTs and the normalized `.vlut`

```dart
final class CubeLut { final String? title; final int size; final bool is1D;
  final List<double> domainMin, domainMax; final Float32List rgb; }      // red fastest, as in the spec
abstract final class CubeParser { static CubeParseResult parse(String text); }   // Isolate.run; issues carry line numbers
abstract final class Vlut { static Uint8List encode(CubeLut lut, {int maxSize = 64}); static VlutInfo info(Uint8List b); }
```

**Parsing:**
* Keywords: `TITLE`, `LUT_3D_SIZE` (the spec allows 2–256; v1 accepts 2–65), `LUT_1D_SIZE`, `DOMAIN_MIN/MAX`, and Resolve's `LUT_3D_INPUT_RANGE`/`LUT_1D_INPUT_RANGE`. `#` starts a comment, and blank lines are allowed.
* The data line count must equal N³ (or N). Errors read like "Line 14: expected 3 numbers" (ux.md §10.7).
* 1D LUTs are converted to 3D at 33³ (with a notice).

**Normalization.** On import, the original `.cube` is copied to `assets/luts/<id>.cube`, and a normalized binary `<id>.vlut` is written next to it. The binary has the magic `VLUT`, a `u8` version, a `u16` size, then `float32` RGB with the domain remapped to [0,1].
* Sizes above 64 are resampled trilinearly to 64. This covers the common 65³ LUTs and stays inside Core Image's documented cube limit [VERIFY: `CIColorCubeWithColorSpace` max dimension on iOS 15+].
* Engines load `.vlut` directly and never parse `.cube`.
* The 12 built-in looks ship as Flutter assets in `.vlut` form. Dart extracts them to `<cache>/looks/` on first use, because Android assets are not plain files.

**Limits.** Sizes above 65, or files over 16 MB, are rejected with the ux.md copy "LUTs up to 65×65×65 are supported." A 65³ text file is about 7 MB and parses in about 0.2 s in an isolate.

---

## 12. RenderPlan (the engine contract)

### 12.1 Principles

1. **Resolved, flat and engine-ready.** Engines never interpret domain concepts: no ripple, no speed ramp, no transition kind, no text animation, no track flags. They get layers with time maps and linear keyframes, a fixed effect set, audio segments with gain envelopes, and assets.
2. **One animation primitive.** Every animated value is `[[tUs, v], …]` in **absolute timeline µs**, linear between keys and held outside them. Easing is pre-sampled by the compiler.
3. **Lowering in Dart** (`lowering_*.dart`) makes preview and export identical on both platforms. Engines need no transition, text-animation or ramp code.
4. **Stable layer ids** (`<itemId>#v`, `#a`, `#bd` backdrop, `#tx<n>` transition helper) and memoized compilation give cheap diffs.
5. **Pure, isolate-safe input and output.** `compileRenderPlan(project, target, resolver)` takes plain data. `AssetResolver` is a sync map from `MediaId` to resolved locator, built beforehand from the port.

### 12.2 Schema (Dart view; JSON Schema `schema/render_plan.v1.schema.json` is normative)

```dart
final class RenderPlan { static const version = 1;
  final int revision; final RenderTarget target;          // preview | export
  final PlanCanvas canvas;                                // w, h (px, even), fps {num, den}, background color
  final TimeUs duration;
  final Map<String, PlanAsset> assets;
  final List<VisualLayer> layers;                         // sorted by z, then start
  final List<AudioSegment> audio;
  final PlanRequirements requirements; }                  // offline, pendingReverse, pendingStill, spritesNeeded
final class PlanAsset { final String id; final PlanAssetKind kind;   // video | audio | image | lut | sprite
  final Map<String, Object?> loc;     // {"path"} | {"uri"} | {"bookmark", "path"} — AppRelative already resolved
  final Map<String, Object?>? proxy;  // preview only
  final int? w, h, rotation; final TimeUs? duration; final String transfer; final bool hasAudio; }
final class VisualLayer {
  final String id; final int z; final TimeRange range; final VisualLayerKind kind;   // media | solid | sprite
  final String? asset; final List<MapSegment> map;        // media: [t0, t1, s0, s1] µs, increasing
  final int? solidColor; final List<SpriteFrame>? sprites;// sprite: [(startUs, assetId)]  (typewriter steps)
  final Size2 base;                                        // px after crop + fit (compiler computed)
  final CropRect crop; final PlanTransform xf;             // cx, cy (px), s, r (deg cw), fx, fy, opacity
  final PlanEffects? fx;                                   // adj{8}, detail{3}, look{lut, i}, chroma{…}, mask{…}
  final Map<String, List<List<num>>> anim;                 // 'cx','cy','s','r','op','adj.exposure','mask.cx',… → [[t, v]]
  final List<PlanMask> extraMasks;                         // wipe-transition masks (canvas space, animated)
  final bool holdFrame; }                                  // freeze placeholder while the still is pending
final class AudioSegment { final String id; final String asset; final int stream; final TimeRange range;
  final List<MapSegment> map; final List<List<num>> gain;  // [[t, linearGain]] full envelope, linear
  final bool maintainPitch; }
final class MapSegment { final TimeUs t0, t1, s0, s1; }    // speed = (s1 − s0) / (t1 − t0)
```

**Transform semantics** (normative, matches `boxAt`):
1. The source frame is rotated to display orientation.
2. `crop` is applied (normalized).
3. The result is scaled to `base`.
4. Flips are applied about the center.
5. The result is scaled by `s`, rotated by `r` degrees clockwise (y-down), and translated so its center lands at (`cx`, `cy`) in canvas px.
6. Opacity multiplies alpha.

The mask is in layer-local normalized coordinates (after crop, before transform), so it moves with the layer. Compositing is premultiplied source-over, ordered by `z`. Within one `z`, a later `range.start` goes on top (the incoming clip during transitions).

**`z` encoding** (compiler-assigned): `z = band·10000 + (laneIndexInBand + 1)·10 + sub`.
* Bands: video 0, overlay 1, text 2, subtitle 3.
* `sub`: 0 for clip layers, +5 for transition helpers (dip solids), −5 for `#bd` backdrops.
* Examples: the main lane is 10, its backdrop is 5, the first text lane is 20010, and the first burned-in subtitle track is 30010.

Engines must treat `z` as an opaque sort key.

**JSON example** (export, abridged):

```json
{"v":1,"rev":128,"target":"export","canvas":{"w":1080,"h":1920,"fps":[30,1],"bg":"#000000FF"},"durUs":61200000,
 "assets":{"md_a1":{"kind":"video","loc":{"path":"/var/…/media/3f/3f9c…/IMG_0012.MOV"},"w":1080,"h":1920,"rot":0,
   "durUs":45000000,"transfer":"hlg","hasAudio":true},
   "spr_9a":{"kind":"sprite","loc":{"path":"/…/sprites/9a…png"},"w":912,"h":148}},
 "layers":[{"id":"it_8Qm2#v","z":10,"t":[0,5000000],"kind":"media","asset":"md_a1","map":[[0,5000000,1000500,8500500]],
   "base":[1080,1920],"xf":{"cx":540,"cy":960,"s":1,"r":0},"anim":{"op":[[4500000,1],[5000000,0]]},
   "fx":{"adj":{"exposure":0.12},"look":{"lut":"lut_teal","i":0.8}}},
  {"id":"it_t1#v","z":20010,"t":[1000000,4000000],"kind":"sprite","sprites":[[1000000,"spr_9a"]],
   "base":[912,148],"xf":{"cx":540,"cy":1500,"s":1,"r":0},"anim":{"op":[[1000000,0],[1300000,1]]}}],
 "audio":[{"id":"it_8Qm2#a","asset":"md_a1","stream":0,"t":[0,5000000],"map":[[0,5000000,1000000,8500000]],
   "gain":[[0,1],[4500000,1],[5000000,0]],"pitch":true}],
 "requirements":{}}
```

### 12.3 Time maps, speed and A/V sync

* **Constant speed** produces one segment. **Ramps** are lowered adaptively: segments split until the error at every frame start is ≤ 250 µs of source time (half the video bias). That is typically 10–40 segments per ramped clip, not one per frame, which keeps AVFoundation compositions small.
* **Video maps** carry the +500 µs bias (§3). **Audio maps** are unbiased and sample-accurate.
* **A/V sync.** A clip's video layer and audio segment share the same segment boundaries. An extracted, linked audio clip compiles from the same `ClipTimeMap`. Engines must keep audio and video of one asset in sync over identical maps. The engine docs define the measurable tolerance (≤ 1 frame drift over 10 min, clap test).
* **Reversed clips** reference the rendition asset with an increasing map (§6.4), so engines never see "reverse".
* **Pitch.** `maintainPitch` maps to `AVAudioTimePitchAlgorithm.spectral` (or `.timeDomain`) versus `.varispeed` on iOS, and to Sonic speed-without-pitch on Android (engine docs). Time-varying speed on Android needs `SpeedProvider`-based effects, or one `EditedMediaItem` per segment [VERIFY Media3 1.11 API].

### 12.4 Lowering rules (compiler)

| Domain concept | Lowered to |
|---|---|
| Track hidden / muted / solo | Layers or segments omitted |
| Fit mode + crop | `base` size (shared `baseSize()`) |
| Item keyframes | `anim` channels, shifted to absolute time |
| Clip fades (audio) | Gain envelope points |
| Volume keyframes × fades × track mute/solo | One multiplied gain envelope (breakpoints merged) |
| **Fade** | Left `op` 1→0 over [cut−d/2, cut], right 0→1 over [cut, cut+d/2], over the background. Audio dips |
| **Dip to black/white** | A `solid` layer (black/white, z above both) with `op` 0→1→0 across the region. Audio dips |
| **Cross dissolve** | Left extended to cut+d/2 and right to cut−d/2 (handle segments at edge speed). Right is above, `op` 0→1. Audio crossfade |
| **Slide (dir)** | Extended as above. Right `cx`/`cy` animate from off-canvas to final, left moves out (both pre-sampled ease-in-out) |
| **Wipe (dir)** | Extended. An `extraMasks` rect on the right layer sweeps across the canvas, feather 2% |
| **Zoom (in/out)** | Extended. Left `s` 1→1.25 with `op` 1→0, right `s` 0.8→1 with `op` 0→1 |
| Text animations (fade/slide/scale) | `op`, `cx`/`cy`, `s` channels from `evaluateTextAnimation`, sampled at its breakpoints |
| Typewriter | `sprites` steps: one sprite per reveal count, merged when several fall in one frame |
| Background `BlurOfMain(r)` | A `#bd` backdrop layer per main-lane clip: same map, `base` = fill canvas, `detail.blur` = r, z below main |
| Missing media | `solid` placeholder (preview: dark gray, plus `requirements.offline`); export not compilable |

Transition helper channels combine with the clip's own keyframes. Opacity multiplies, and translate and scale apply on top of the user transform. The compiler evaluates both sets on a merged breakpoint set, so each layer emits a single `anim` channel.

### 12.5 Text and subtitles (decision 9)

* **Preview:** the plan has **no** text or subtitle layers (`target: preview`). ux.md draws them in a Flutter overlay from `textLayoutSpecOf` and `evaluateTextAnimation`, the same functions the compiler uses.
* **Export:** the steps run in this order.
  1. `collectSpriteRequests(project, settings) → List<SpriteRequest(key, TextLayoutSpec, reveal?)>` (pure).
  2. danaview_editor's `TextSpriteRasterizer` lays out each spec with `ui.ParagraphBuilder` at canvas px, draws it with `ui.PictureRecorder` and encodes it with `toByteData(format: png)`. The encode is native and asynchronous [VERIFIED API, perf to measure]. Output goes to `<cache>/sprites/<key>.png` and returns a `SpriteManifest` (key → px size).
  3. `compileExport(project, settings, manifest)` places the sprites. Text uses its transform center. Subtitles are anchored by `SubtitlePosition` using the sprite height.
* **Keys** are `sha1(canonical TextLayoutSpec JSON + canvas size)`, so re-exports reuse sprites and the "Preparing captions" phase is O(new cues). 3,000 cues take about 10–15 s the first time (estimate).
* `TextLayoutSpec` contains the runs (with `<i>`/`<b>` spans), family, px size, weight, italic, letter spacing, line height, alignment, max width, color, stroke, shadow, box, `maxLines`, and direction `auto` (first strong character, ai.md §10.4). Script fallback (CJK, Arabic, Devanagari) uses Flutter's system font fallback, and it's identical in preview and export because both are Flutter.

### 12.6 Requirements and blockers

`PlanRequirements { offline: Set<MediaId>; pendingReverse: Set<ItemId>; pendingStill: Set<MediaId>; spritesNeeded: List<SpriteRequest> }`. A preview plan always compiles and uses placeholders. `compileExport` returns `ExportBlocked(requirements)` instead of a plan when any blocker is present, and those blockers drive ux.md §11.1's pre-checks.

### 12.7 Diff, patches and transients

```dart
RenderPlanPatch diffPlans(RenderPlan a, RenderPlan b);   // identity-first: memoized layers are `identical` when unchanged
final class RenderPlanPatch { final int fromRevision, toRevision; final PlanCanvas? canvas; final TimeUs? duration;
  final List<VisualLayer> upsertLayers; final List<String> removeLayers; final List<AudioSegment> upsertAudio;
  final List<String> removeAudio; final Map<String, PlanAsset> upsertAssets; final List<String> removeAssets; }
PlanTransient transientFor(EditProject working, ItemId item);  // compiled layers of one item, sent as override
```

* **Memoization.** `PlanMemo` holds an `Expando` keyed by item identity, plus a context signature: track flags, neighbor and transition identity, settings identity, and asset identity. With structural sharing, a one-item edit at 2,000 items recompiles only that item and its transition neighbors.
* **Order.** Patches apply atomically and in order. If the engine's revision doesn't match `fromRevision`, the engine returns `planRejected` and ux.md's `PlanSync` sends a full plan.
* **Transients** (ux.md §16.4) reuse the layer schema, are never assigned a revision, and are dropped on the next patch or `clearTransient`.
* **Property guarantee.** `apply(diff(a, b), a) == b` for random project pairs (DOM-31).

### 12.8 Transport and versioning [DECISION]

* **The plan travels as UTF-8 JSON bytes (`Uint8List`)** inside the engine control API. Pigeon is recommended for that API (methods, clock events, job progress). The engine docs own it.
* **Why not model the plan in Pigeon:**
  * The plan is a deep, sparse and evolving tree (unions of layer kinds, optional effect blocks).
  * It must be diffed, golden-tested, dumped into bug reports and produced in isolates.
  * JSON gives one human-readable contract that Swift `Codable` and Kotlin `kotlinx.serialization` (or `org.json`) decode directly.
* **Cost.** A full 2,000-item plan is about 0.8 MB. Encoding takes about 20 ms in an isolate, and native decoding about 10–30 ms [estimate]. Full plans are sent only at open, after canvas or frame-rate changes, and on `planRejected`. Patches are a few KB.
* **Versioning.** Every plan and patch carries `"v"`. `EditorEngine.capabilities()` reports `planVersions: [1]`. The compiler emits the highest common version. Additive fields need no version bump, because decoders ignore unknown keys. A meaning change bumps `v`, and the compiler keeps the previous emitter for one release.

### 12.9 Contract tests (cross-language)

* `test/fixtures/render_plans/*.json` holds about 25 plans, one per feature: ramps, every transition, masks, chroma, LUT, backdrop, sprites, offline, HDR asset and patches.
* Dart goldens: `compile(fixtureProject) == fixturePlan`.
* Each fixture validates against the JSON Schema.
* The iOS XCTest and Android JUnit suites (engine tickets) decode every fixture, re-encode it, and assert semantic equality. Unknown keys must be ignored.
* Engine golden-frame tests render selected fixtures and compare against reference PNGs: ΔE2000 ≤ 2 for color, ±1 px for geometry.

---

## 13. Export settings and presets

```dart
final class ExportSettings {
  final String presetId;                    // youtube | youtube4k | shorts | reels | igFeed | tiktok | custom
  final ExportContainer container;          // mp4 | mov (capabilities.movContainer; iOS only in practice)
  final VideoCodec codec;                   // h264 | hevc (capabilities.hevcEncode)
  final int width, height;                  // even; output canvas; project canvas fitted inside
  final FrameRate frameRate;                // ≤ project rate by default
  final int videoBitrate;                   // bps; auto from table × quality, clamped by capabilities
  final ExportQuality quality;              // smaller ×0.6 | balanced ×1.0 | high ×1.5 | maximum ×2.0
  final int audioBitrate, audioSampleRate /*48000*/, audioChannels /*2*/;   // AAC-LC
  final int keyframeIntervalMs;             // 2000; best effort
  final Set<TrackId> burnInSubtitles;       // default: tracks with burnIn
  final ExportFit fit;                      // letterbox (default) | fill — never silent crop (ux.md §11.2)
  final ExportColor color;                  // sdrRec709 only in v1; HLG/PQ sources tone-mapped by engines
  final bool stripLocation;                 // true: no GPS/location metadata in output (privacy)
}
```

There is no hardware toggle (ux.md §11.6). Engines always request the hardware encoder and report a fallback in `ExportResult`. `ExportSettings` and the export `RenderPlan` are both serialized into the engine's `startExport` call, as two JSON documents with the same `"v"` rules.

**Presets.** The table lives in `export_presets.dart` and the UI reads it. These are platform hints, not enforced limits [VERIFY current platform guidance]:

| Preset | Size (9:16 shown as W×H) | FPS | Codec | Video | Audio |
|---|---|---|---|---|---|
| YouTube | short side 1080, project aspect | project, max 60 | H.264 High | 8 Mbps ≤30 fps / 12 Mbps >30 | 192 kbps, 48 kHz |
| YouTube 4K | short side 2160 (capability-gated) | project, max 60 | HEVC if supported, else H.264 | H.264 40 / 60 Mbps; HEVC ×0.6 | 256 kbps |
| YouTube Shorts | 1080×1920 | project, max 60 | H.264 | 8 / 12 Mbps | 192 kbps |
| Instagram Reels | 1080×1920 | 30 | H.264 | 8 Mbps | 128 kbps |
| Instagram Feed | 1080×1350 | 30 | H.264 | 6 Mbps | 128 kbps |
| TikTok | 1080×1920 | 30 (60 if project 60) | H.264 | 8 Mbps | 128 kbps |
| Custom | 720/1080/1440/2160 short side; 24/25/30/50/60 | | H.264/HEVC | 2–100 Mbps | 96–320 kbps |

**Auto bitrate.** The table is indexed by short side {720: 5/7.5, 1080: 8/12, 1440: 16/24, 2160: 40/60} Mbps for ≤30 or >30 fps, multiplied by 0.6 for HEVC and by the quality factor, then clamped by `EditorCapabilities`.

**Size estimate.** `estimateBytes = (video + audio)·durationSec/8·1.02` (ux.md §11.3).

**Aspect.** `aspectMismatch(project, preset)` returns the ux.md notice. The export plan's canvas equals the output size, and the compiler scales and letterboxes everything, so engines just render.

**Frame rate.** Media3 Transformer can only *drop* frames (`FrameDropEffect`) and does not duplicate them [VERIFY]. So Android export frame rates above the source rate behave as caps, and capabilities report `fpsUpconversion: false`.

---
## 14. Threading and performance budgets

| Work | Where | Budget (p95, mid-tier phone, AOT) |
|---|---|---|
| `apply` / `dryRun` (one lane changed) | Main isolate | apply ≤ 2 ms; dryRun ≤ 1 ms at 1,000 items (ux.md §22) |
| Incremental validation of changed lanes | Main isolate | ≤ 0.3 ms |
| `SnapIndex.build` | Main isolate, once per drag | ≤ 1 ms at 2,000 items |
| Plan compile, incremental (memoized) + diff + patch encode | Main isolate | ≤ 3 ms for a one-item edit at 2,000 items |
| Plan compile, full (open, canvas/fps change, rejected patch) | `Isolate.run` when > 300 items | ≤ 60 ms at 2,000 items, plus JSON encode ≤ 25 ms |
| Autosave encode (fragment cache) | Main isolate | ≤ 3 ms incremental; ≤ 40 ms cold, once per open |
| Hash + atomic write | Writer isolate + I/O threads | ≤ 50 ms for 1 MB |
| Open: read + migrate + decode + validate + repair | `Isolate.run` (result returned with `Isolate.exit`, no copy) | ≤ 150 ms at 2,000 items |
| SRT/VTT parse (10k cues), `.cube` 65³ parse | `Isolate.run` | ≤ 100 ms; ≤ 250 ms |
| `quickHash` | Port (native for URIs) or `dart:io` | ≤ 10 ms per file |
| History memory | Main isolate | ≤ 48 MB approx (policy cap) |

The design target matches ux.md §17.6: 2,000 items, 32 lanes, 3 h, 300 media files, and 3,000+ cues. `benchmark/` runs these with `dart compile exe` and synthetic projects. CI fails on a > 25% regression against the stored baseline (DOM-33).

---

## 15. Error handling

* **Commands:** `EditRejection` is data. ux.md maps it to copy in `editor_messages.dart`. A command never throws. An unexpected exception inside a command is caught by `EditSession` and becomes `InternalInconsistency`, and the project is unchanged.
* **Store:** `StoreFailure { kind: diskFull | permissionDenied | notFound | corrupt | newerSchema | busy | io; detail }`. Public APIs return or throw only `StoreFailure`, and raw `FileSystemException`s are mapped (ENOSPC → `diskFull`).
* **Open:** never throws for content problems. It returns `ProjectHealth` plus `ProjectOpenWarning`s (repairs, unknown enum values, stripped data).
* **Codecs:** parse results carry `issues` with line numbers. Only "nothing usable" is a failure.
* **Ports:** typed `MediaAccessFailure { missing, accessLost, unsupported, io }`. Engines must never surface a raw `PlatformException` across the boundary (ux.md §2.3).
* **Ownership violations:** `OwnershipViolation` is thrown, logged, and asserted against in debug. It always indicates a bug, and the delete never happens.

---

## 16. Testing strategy

| Layer | What | Where / how |
|---|---|---|
| Unit (pure Dart) | Time math properties; each command's before/after goldens and every rejection; keyframe partitioning on split/trim/speed; ramp closed forms (numerical integration cross-check ≤ 1 µs); `boxAt` vs compiler parity; snapping; selection expansion; history (coalescing, limits, pool deltas); transactions (update idempotence, cancel) | `packages/danaview_editor_core/test/**`, `dart test` |
| Model fuzzer | Random projects × random command sequences (seeded): full validator after each step; `undo^n` restores `identical` tracks, markers and settings (root re-stamped); `redo^n` likewise; revision stamps never repeat; JSON round trip equal; diff/patch property. 200 seeds × 500 steps in CI, 10k nightly | `test/fuzz/` |
| Codec and migration | Encode/decode equality; deterministic bytes; fixture corpus per schema; corrupt, torn and truncated inputs; newer-schema handling | `test/codec/`, `fixtures/projects/` |
| Persistence | Every crash point via `FaultInjectingFs`; recovery listing and restore/discard; duplicate, rename, delete; GC never deletes outside roots or external assets (symlink and `..` fuzz); grant release | `test/store/` with temp dirs |
| Formats | SRT/VTT corpus incl. BOMs, UTF-16, CJK, RTL, malformed; `.cube` corpus (Resolve, Adobe, 1D, domain ranges, 65³) | `test/formats/` |
| RenderPlan | Compile goldens; JSON Schema validation; lowering tables (§12.4) per transition kind; sprite placement | `test/plan/`, `fixtures/render_plans/` |
| Cross-language contract | Swift and Kotlin decode/re-encode every plan fixture; golden frames | Engine tickets (§12.9) |
| Widget | None in this package. UX widget tests use the real `EditSession` with `FakeEditorEngine` (ux.md §21.2) | ux.md |
| On-device | `integration_test/editor_store_test.dart` (in danaview_editor): crash-recovery (abandon session → reopen → recoverable); large-project save/open timing; bookmark (iOS) and persisted-grant (Android) survival across app restart via native instrumentation | DOM-34, jointly with the engine areas |
| Performance | `benchmark/*` thresholds (§14) | CI `editor-core.yml` |

---

## 17. Cross-area interfaces and deltas

| Interface | Counterpart | Status vs sibling doc |
|---|---|---|
| `EditProject`, `TrackId`/`ItemId`/`MediaId`/`MarkerId`, `FrameRate`, `TimeRange`, `TrackKind`, `TimelineItem`/`MediaClip`/`TextItem`/`SubtitleCue`, `EditCommand`, `EditOutcome`, `EditRejection`, `applyCommand`, `dryRun`, `evaluate`, `boxAt`, `TextMetricsProvider`, `compileRenderPlan`, `diffPlans`, `PropertyKey` metadata, `KeyframeRef`, `TransitionRef`, `EditHistory` | ux.md §2.1 | **Adopted names.** `EditHistory` becomes `EditSession.history` (+ `HistoryStatus`). `dryRun` returns `EditPreview` with `placements`, `createsTracks` and `clampedTo`. `SnapIndex` is provided in core, and ux.md's `snapping.dart` should wrap it. `FrameRate` fields are `num`/`den` |
| Lane order | ux.md §8.3 | **Delta:** extra video lanes are *above* the main lane (main = bottom of the video band) |
| Transactions | ux.md §16.4 | `SessionTransaction` implements the same semantics in core. UX's `EditTransaction` delegates to it and adds frame-coalesced emission and transients |
| Relink as one history entry | ux.md §13.2 | Supported via `PoolEdit` ("Relink media"). Imports are never undone |
| `ProjectRepository`, `MediaPoolService`, `LoadedProject`, `ProjectSummary`, `RecoverableSession` | ux.md §2.2 | Fulfilled (§9.6, §10.1). Repository methods take the `EditSession` where state is needed. Adds `requestAutosave`, `flush`, `close`, `storageReport`, and `ProjectHealth.readOnlyNewer` |
| Text rendering (ux.md Q3) | ux.md, engines | **Decision 9:** Flutter overlay in preview, Flutter-rasterized sprites in export. UX owns `TextSpriteRasterizer` and the overlay painter. Both must use `textLayoutSpecOf` and `evaluateTextAnimation` |
| Fade semantics (ux.md Q5) | ux.md | Fade = through background, no overlap. Cut = clipboard cut (`CompositeCommand`) |
| Speed range (ux.md Q12) | ux.md, engines | 0.1×–10×, clamped by capabilities |
| RenderPlan JSON + Schema + fixtures; `kVideoSampleBiasUs`; effect order; `.vlut` | iOS and Android engines | This area defines; engines implement and contract-test (§12.9). Engines report `planVersions` and `fpsUpconversion` in `EditorCapabilities` |
| `MediaAccessPort` (resolve, stat, quickHash, persist/release, excludeFromBackup, grant budget) | Engine package | This area defines; engines implement on iOS/Android. `dart:io` default for paths |
| `MediaProbe` (display size, rotation, rational fps, VFR flag, transfer, streams) | Engines (`probe`) | Required for project creation, relink and fit |
| `MediaJobs.reverse/freezeFrame` results → pending/ready pool assets | Engines, ux.md | Results arrive as `PoolChange.UpdateAsset`. Spec hash = `sha1(kind, quickHash, range/time, paramsVersion)` |
| `TimelineView`, `AudibleClipView.timelineTimeOf` | ai.md §10.1 | `ClipTimeMap.timelineTimeOf` is exact for constant speed and ramps. The adapter (AI-13) is thin. `AudioRole` is on `Track` |
| `AddGeneratedCaptionTrack`, `ReplaceGeneratedCaptions`, `CaptionProvenance`, `CueOrigin`, `editedAfterGeneration`, `SubtitleCueDraft` | ai.md §10.2 | **Adopted verbatim** in core (`ops/commands/caption_commands.dart`, `model/caption_provenance.dart`). Already in schema s1, so **no schema bump** |
| `MediaRef` in `SpeechAudioRequest` | ai.md §7.1 | **Delta:** `danaview_domain` already has a player `MediaRef`. Use `MediaId` plus a `ResolvedMedia` from `MediaAccessPort.resolve` instead. `mediaFingerprint` = `MediaFingerprint.quickHash` |
| Backup rules for `danaview/speech/*` and `danaview/editor/{media,derived}` | ai.md §5.4, Android | One `data_extraction_rules.xml` co-owned (DOM-28) |
| `StorageContributor` sizes | ux.md §4.8 | `ProjectRepository.storageReport()` supplies "Editor projects". The cache contributor measures `<cache>/danaview/editor` |

---

## 18. Risks, uncertainties and open questions

**Platform claims to verify** (each one is an acceptance criterion in a ticket):

| # | Claim | Confidence | Ticket |
|---|---|---|---|
| V1 | `RandomAccessFile.flush()` / `writeAsBytes(flush: true)` performs an fsync on iOS and Android | Medium | DOM-24 |
| V2 | Android Photo Picker URIs accept `takePersistableUriPermission`; persisted grant cap 512 (API 30+) / 128 before | Medium | DOM-27 / Android |
| V3 | iOS document-picker URLs can be bookmarked and resolved across launches without `.withSecurityScope` (macOS-only) | High | DOM-27 / iOS |
| V4 | `NSURLIsExcludedFromBackupKey` on a directory excludes its contents | Medium-high | DOM-28 |
| V5 | Core Image color cube maximum dimension (64 vs higher) | Medium | DOM-21 |
| V6 | Media3 1.11: time-varying speed (`SpeedProvider`) for ramps in Transformer and CompositionPlayer; `FrameDropEffect` cannot duplicate frames | Medium | DOM-30 / Android |
| V7 | `ui.Image.toByteData(format: png)` speed for caption sprites (3,000 cues ≤ 15 s first export) | Medium | ux.md, DOM-32 |
| V8 | Dart `File.copy` uses APFS clone on iOS (fast copies) | Low | DOM-27 (perf only) |
| V9 | Preset bitrates and sizes match current YouTube/Instagram/TikTok guidance | Medium | DOM-32 |

**Risks:**
* **Head/tail fingerprint collisions.** Mitigated: relink also compares duration and dimensions.
* **iCloud-evicted files referenced by bookmark.** `stat` reports `accessLost` or `missing`. The engine area should add `NSFileCoordinator` download.
* **Grant budget exhaustion** on heavy Android users. Mitigated with the managed-copy fallback and GC release.
* **Sprite generation time for very long caption tracks.** Mitigated by caching and preparing during the export pre-checks.
* **Users may want text behind overlays.** This is blocked by decision 9 until a native text path exists (the schema already carries `TextLayoutSpec`).
* **Snapshot history memory on pathological edits** (Apply to all on 2,000 items). Mitigated by the bytes cap, which evicts the oldest entries.

**Open questions:**

| # | Question | Recommendation | Decider |
|---|---|---|---|
| O1 | Ripple across all unlocked lanes (sync lock), or edited lanes + links only | Edited + linked lanes in v1 | Owner |
| O2 | Text/subtitle always above overlays (decision 9) | Accept for v1 | Lead + owner |
| O3 | Opening newer-schema projects read-only vs blocked | Read-only when `minReader` allows | Owner |
| O4 | iOS Files imports: reference in place (bookmark) vs copy for robustness | Reference (saves storage); show `accessLost` clearly | Owner |
| O5 | Max project length 24 h, max items 5,000 (`LimitExceeded`) | Accept | Lead |

---

## 19. Implementation tickets (this area)

Milestones: **M1** foundations → **M2** operations → **M3** formats → **M4** persistence → **M5** RenderPlan → **M6** hardening. UX and AI tickets can start against M1 types and fakes. Engines can start on the M5 schema and fixtures as soon as DOM-29 lands.

**DOM-01 Package scaffold, purity and CI** · *Files:* `packages/danaview_editor_core/{pubspec.yaml,analysis_options.yaml,lib/*.dart}`, `test/purity_test.dart`, `.github/workflows/editor-core.yml` · *Depends:* none · *AC:* `dart test` passes with no Flutter SDK on PATH. The purity test fails on any `package:flutter`/`danaview_*` import and on `dart:io` outside `store/`. The CI workflow runs on PRs that touch `packages/danaview_editor_core/**`.

**DOM-02 Time and ids** · *Files:* `src/time/*`, `src/ids/*` · *Depends:* DOM-01 · *AC:* round-trip properties hold for all supported rates and every k ≤ 24 h. `Timecode.parse(format(t)) == quantize(t)`. `SeededIdGenerator` is deterministic.

**DOM-03 Core model types** · *Files:* `src/model/**` (excluding `pool/` and `keyframes/`) · *Depends:* DOM-02 · *AC:* every type is `@immutable` with `copyWith`. Value types have `==`/`hashCode`. Track and item lists are unmodifiable. `EditProject.index` is lazy and cached. ux.md §2.1 getters exist.

**DOM-04 Media pool model** · *Files:* `src/model/pool/*` · *Depends:* DOM-03 · *AC:* sealed `MediaLocator`. `MediaFingerprint.quickHash` equals `MediaIdentityService.computeQuickHash` on 6 fixture files (test reads `danaview_data`'s algorithm output from fixtures, not the package).

**DOM-05 Property keys and keyframes** · *Files:* `src/model/keyframes/*`, `src/eval/evaluate.dart` · *Depends:* DOM-03 · *AC:* registry covers every §4.11 property with metadata. Linear interpolation and hold are correct. Vec2 keys write both channels. Out-of-range keys are kept but ignored.

**DOM-06 Clip time map and speed math** · *Files:* `src/eval/{clip_time_map,speed_math}.dart` · *Depends:* DOM-03 · *AC:* closed forms match numerical integration within 1 µs over random ramps. `timelineTimeOf(toSource(t)) == t ± 1 µs`. Reversed maps are verified. `crop` keeps content speeds. `lower(maxErrorUs: 250)` stays within error.

**DOM-07 Geometry and text evaluation** · *Files:* `src/eval/{geometry,text_layout_spec,text_animation_eval,transition_limits}.dart` · *Depends:* DOM-05, DOM-06 · *AC:* `boxAt` uses the same `baseSize`/transform functions as the compiler (shared-code test). Text animation states are exact at breakpoints. Typewriter counts graphemes (emoji, combining marks).

**DOM-08 Validator and repair** · *Files:* `src/validate/*` · *Depends:* DOM-04, DOM-05 · *AC:* each invariant I1–I9 has a failing fixture. `repair()` fixes each one with a warning. Incremental `only:` matches full validation on the fuzz corpus.

**DOM-09 Command framework and dry run** · *Files:* `src/ops/{edit_command,rejections,outcome,edit_context,placement,dry_run}.dart`, `commands/composite.dart` · *Depends:* DOM-08 · *AC:* commands are pure (same input + seeded ids gives an equal output). Rejections never throw. Composite is atomic. `noop` is detected. `dryRun` takes ≤ 1 ms at 1,000 items (benchmark).

**DOM-10 Structural clip commands** · *Files:* `commands/{clip_commands,ripple}.dart` · *Depends:* DOM-09, DOM-06 · *AC:* InsertMedia, MoveItems, TrimItem, SplitItems, DeleteItems and DeleteGap behave per §6.2 and §6.3, including ripple, overlap→new lane, links, clamp mode and keyframe/fade/transition carry-over. Split-concatenation equals the original map at every frame.

**DOM-11 Duplicate, clipboard, replace, extract audio, links** · *Files:* `commands/clip_commands.dart` (part), `src/ops/clipboard.dart`, `selection.dart` · *Depends:* DOM-10 · *AC:* cross-project paste adds pool entries and mints new ids. Replace shortens with a notice. Extract audio links and detaches. `SelectionRules.expand` is correct.

**DOM-12 Speed, reverse and freeze commands** · *Files:* `commands/speed_commands.dart` · *Depends:* DOM-10 · *AC:* speed presets and custom values in [0.1, 10]. Ramps keep the source range and recompute duration. Keys scale. Freeze inserts with ripple. Reverse flips only the flag.

**DOM-13 Property and keyframe commands** · *Files:* `commands/{property_commands,keyframe_commands}.dart` · *Depends:* DOM-09, DOM-05 · *AC:* `SetProperty` is keyframe-aware at a quantized `at`. Multi-item edits produce one outcome. Add/remove/move/edit/clear keyframe rejections are covered. Reset transform clears keys.

**DOM-14 Text commands** · *Files:* `commands/text_commands.dart` · *Depends:* DOM-13 · *AC:* AddText goes to the top free text lane. SetText with `coalesceKey` merges within 1 s (session test). Style and animation validation bounds hold.

**DOM-15 Subtitle and caption commands** · *Files:* `commands/{subtitle_commands,caption_commands}.dart`, `model/caption_provenance.dart` · *Depends:* DOM-10 · *AC:* §6.7 rules hold. Overlapping imports spill to a second track. `editedAfterGeneration` is set on edit. Both AI commands are single history entries, fresh ids, `TrackLocked` honored, and `replaceInRange` replaces only overlapping cues.

**DOM-16 Transitions** · *Files:* `commands/transition_commands.dart`, `eval/transition_limits.dart` · *Depends:* DOM-10 · *AC:* `maxFrames` is correct for handles, speed, reversed clips and images. Adjacency-breaking edits drop transitions and undo restores them. Apply-to-all is one entry.

**DOM-17 Tracks, markers, project settings** · *Files:* `commands/{track_commands,marker_commands}.dart`, `ops/requantize.dart` · *Depends:* DOM-09 · *AC:* band ordering enforced. The main track is protected. Requantize properties (order preserved, bounded movement) hold over all rate pairs.

**DOM-18 Snapping** · *Files:* `src/ops/snapping.dart` · *Depends:* DOM-03 · *AC:* `nearest` and `nearestForRange` are correct on random sets. Build takes ≤ 1 ms at 2,000 items.

**DOM-19 EditSession, history and transactions** · *Files:* `src/session/*`, `test/fuzz/*` · *Depends:* DOM-09 (the session); DOM-10 (the fuzzer, which grows as DOM-11–17 land) · *AC:* snapshot undo/redo/jump. Pool deltas for relink and remove, sticky imports. Coalescing and limits work. Transaction `update` applies to the base and `cancel` restores it. `retainedMedia()` is correct. A fuzzer (200×500 in CI) checks the invariants plus undo/redo identity.

**DOM-20 SRT/VTT codec** · *Files:* `src/formats/{subtitle_codec,srt,vtt,text_decoding}.dart` · *Depends:* DOM-02 · *AC:* corpus passes. Round trip holds for the supported subset. Issues carry line numbers. 10k cues parse in ≤ 100 ms in an isolate.

**DOM-21 `.cube` parser and `.vlut`** · *Files:* `src/formats/{cube_lut,vlut}.dart`, `danaview_editor/assets/looks/*.vlut` (12 looks; content from the owner/UX) · *Depends:* DOM-01 · *AC:* corpus passes (Resolve, Adobe, 1D → 3D, domain remap). 65³ resamples to 64³ with max error ≤ 1/255. V5 resolved.

**DOM-22 Project JSON codec** · *Files:* `src/codec/{project_json,fragment_cache,schema_version}.dart`, `schema/project.v1.schema.json` · *Depends:* DOM-03, DOM-04, DOM-05 · *AC:* deterministic bytes. Decode(encode(p)) == p. Incremental re-encode after a one-item edit takes ≤ 3 ms at 2,000 items. Unknown enums produce a warning.

**DOM-23 Migration framework** · *Files:* `src/codec/migrations/*`, `test/fixtures/projects/s0,s1/*` · *Depends:* DOM-22 · *AC:* the test-only s0→s1 migration runs. Pre-migration backup is written on first save. `needsNewerApp` and `readOnlyNewer` are detected from the header alone.

**DOM-24 Store filesystem and atomic writes** · *Files:* `src/store/{store_roots,store_fs,atomic_file,dnproj_format,owned_file_deleter}.dart` · *Depends:* DOM-22 · *AC:* `FaultInjectingFs` crash at every step always yields a valid main, tmp or bak. Checksums detect truncation. The deleter rejects outside-root paths, symlinks and external assets (fuzz). V1 is verified on device (fsync via strace/Instruments or documented source).

**DOM-25 ProjectRepository** · *Files:* `src/store/{project_repository,file_project_repository,project_summary,storage_report}.dart` · *Depends:* DOM-24, DOM-19 · *AC:* create (empty or fromMedia with settings derivation), open, save, rename, duplicate (shares managed media), delete (trash then guarded delete), `watchSummaries`, `findUntouchedProjectFor`, `ProjectBusy`, and `storageReport` all work.

**DOM-26 Autosave, journal and recovery** · *Files:* `src/store/{autosave_scheduler,journal,recovery}.dart` · *Depends:* DOM-25 · *AC:* debounce is 2 s with a 10 s cap, and it pauses during transactions. Slots alternate. Recovery lists only newer journals with a matching `baseSaveId`. Restore, discard and the "recovered-<ts>" retention all work. Disk-full produces `SaveStatus.failed` and a retry.

**DOM-27 Media pool service and import policy** · *Files:* `src/store/{media_pool_service,media_access_port,import_policy,managed_store}.dart` · *Depends:* DOM-25 · *AC:* the §10.1 table is implemented against a fake port. Dedupe by `quickHash` works. Temp copies are moved only when the deleter allows it. The grant-budget fallback works. V2, V3 and V8 are resolved with the engine areas.

**DOM-28 Availability, relink, GC and backup rules** · *Files:* `src/store/{availability,relink,gc}.dart`, `android/app/src/main/res/xml/{data_extraction_rules,backup_rules}.xml` + manifest attributes (joint with Android and AI) · *Depends:* DOM-27 · *AC:* the §10.3 states are detected. `checkRelink` outcomes and a one-entry undoable relink work. GC mark (incl. `retained`), sweep with the 24 h grace, and grant release work. GC never runs during export. V4 is resolved.

**DOM-29 RenderPlan schema v1 and fixtures** · *Files:* `src/plan/{render_plan,plan_json}.dart`, `schema/render_plan.v1.schema.json`, `schema/effects_reference.md`, `test/fixtures/render_plans/*` · *Depends:* DOM-03 · *AC:* about 25 fixtures validate against the schema, and Dart decode/encode is stable. This ticket is **delivered early** to unblock the engine contract tests.

**DOM-30 Plan compiler and lowering** · *Files:* `src/plan/{compiler,lowering_transitions,lowering_text,lowering_audio,sprite_requests}.dart` · *Depends:* DOM-29, DOM-07, DOM-16 · *AC:* every §12.4 row has a golden. Bias is applied to video only. Ramps lower within 250 µs. Hidden, muted and solo are honored. Offline and pending items produce placeholders and requirements. V6 is resolved with Android.

**DOM-31 Diff, patch, memoization and transients** · *Files:* `src/plan/{plan_diff,plan_memo}.dart` · *Depends:* DOM-30 · *AC:* `apply(diff(a, b), a) == b` (fuzz). A one-item edit at 2,000 items compiles and diffs in ≤ 3 ms. A full compile in an isolate takes ≤ 60 ms. Transients contain only the item's layers.

**DOM-32 Export settings, presets and export compile** · *Files:* `src/plan/{export_settings,export_presets,bitrate}.dart` · *Depends:* DOM-30 · *AC:* preset table is per §13. Auto bitrate, capability clamps and the size estimate work. Aspect-mismatch detection works. `compileExport` returns `ExportBlocked` correctly and places sprites (text and burn-in) from a manifest. V7 and V9 are reviewed.

**DOM-33 Large-project performance pass** · *Files:* `benchmark/*`, `test/fixtures/projects/large_2000.json` · *Depends:* DOM-19, DOM-26, DOM-31 · *AC:* all §14 budgets are met in AOT on the benchmark host and on one mid-tier Android and one iPhone (via ux.md's perf harness). The CI regression gate is active.

**DOM-34 On-device persistence and media-access tests** · *Files:* `packages/danaview_editor/integration_test/editor_store_test.dart` (UX-owned harness), plus native instrumentation in the engine packages · *Depends:* DOM-26, DOM-28, engine `MediaAccessPort` · *AC:* crash recovery after a forced kill restores the last edits. A bookmark (iOS) and a persisted grant (Android) survive an app restart. Excluded directories are not in the backup (manual check documented).

**DOM-35 Developer documentation** · *Files:* `packages/danaview_editor_core/README.md`, root `README.md` architecture section · *Depends:* DOM-31 · *AC:* documents the package boundaries, command-authoring checklist (purity, rejection, validator, fuzz registration), schema/migration procedure and plan versioning rules.
