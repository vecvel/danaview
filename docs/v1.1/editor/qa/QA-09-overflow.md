<!-- OWNER: QA-09 -->

# QA-09 · No-overflow matrix

The owner's rule 5 (ARCH §1.3): nothing overflows at widths 280–1280 px and text scale 0.85–1.35. ARCH §17.9 defines the matrix this suite enforces.

## The matrix

| Axis | Values |
|---|---|
| Size (logical px) | 280×500, 320×568, 360×740, 390×844, 412×915, 568×320, 667×375, 844×390, 932×430, 744×1133, 834×1194, 1133×744, 1194×834, 1280×800 |
| Text scale | 0.85, 1.0, 1.35 |
| Keyboard inset | none, 40 % of the height |
| Platform | iPad-class sizes run as iOS, 1280×800 and the phones run as Android (`SurfaceMatrix.platformFor`) |

That makes 84 surfaces (`SurfaceMatrix.full`). The **PR subset** (`SurfaceMatrix.pr`) has 6 surfaces: 280×500 @1.35, 568×320 @1.35, 390×844, 390×844 with the keyboard (iOS), 834×1194 (iOS) and 1280×800 @0.85. Together the 84 surfaces resolve to all four editor layout kinds (compactPortrait, compactLandscape, medium, expanded), with the inspector both open and closed. A unit test asserts this.

## What each test checks

For every state of every surface:

- **`takeException() == null`**: no overflow, layout or build error. The rig collects every framework error with its own message, so one run lists all of them instead of stopping at the first.
- **`expectInside`**: the fixed chrome lies inside the screen. This covers the editor top bar, the inspector header and its dock or side pane, the Projects "New" button and the recovery dialog buttons.
- **`fitsFully`**: no visible `DanaviewButton` label and no `DanaviewSectionHeader` is cut by its line limit.

The suite **loads the real fonts**: Figtree from danaview_ui_kit, plus the 10 content fonts. Labels are measured with the glyphs users see. The test font draws every glyph as a 1 em square, which is about 1.8× wider than Figtree, so with it every narrow button would report a false truncation.

Every surface is rendered with **long-content fixtures** (`test/overflow/overflow_fixtures.dart`):

- an 80-character project name (the model's limit)
- long track names
- long media file names without spaces
- a two-line text overlay with a 34-letter word
- two-line captions
- long marker names and notes
- 6 lanes (video with a cross dissolve, overlay, text, subtitles, music, voice)
- a Projects list with every badge and two recoverable sessions

## Surfaces → tests

All danaview_editor tests run on the PR subset in flutter-packages CI. The nightly script runs them on the full matrix.

| Surface (BUILD_PLAN QA-09) | QA-09 long-content suite (`packages/danaview_editor/test/overflow/`) | Per-ticket matrix tests (deeper states) |
|---|---|---|
| Projects | `screens_overflow_test.dart`: long list with badges, recovery banner and footer, scrolled through; empty state | `test/projects/projects_screen_test.dart` |
| New project | `screens_overflow_test.dart`: New project and Rename sheets | `test/flows/import/new_project_sheet_test.dart`, `import_media_sheet_test.dart` |
| Editor in 4 layouts | `editor_inspector_overflow_test.dart`: real EditorScreen idle, with each item kind selected and with the transition selected | `test/layout/editor_screen_layout_test.dart`, timeline, transport, tool strip, preview and render-preview matrix tests |
| Every inspector panel | `editor_inspector_overflow_test.dart`: all 17 routes, every text tab, both audio focuses, every subtitles section, the Captions start state | each panel's test under `test/panels/`, `test/inspector/` |
| Every flow sheet | `editor_sheets_overflow_test.dart`: project, history, tasks, export, shortcuts, add track, move to track, marker, export subtitles, freeze frame, fullscreen preview, and the track menu of every lane kind | project, history, tasks, subtitle I/O and shortcuts matrix tests |
| Export | `editor_sheets_overflow_test.dart` (setup) | `test/flows/export/export_sheet_test.dart` (progress, completion, failures) |
| Captions | `editor_sheets_overflow_test.dart` (Auto captions sheet) | `auto_captions_matrix_test.dart`, `regenerate_matrix_test.dart` |
| Relink | `editor_sheets_overflow_test.dart`: missing-media banner in the editor, relink sheet with missing, access-lost and changed media | `test/flows/relink/relink_matrix_test.dart` |
| Recovery | `screens_overflow_test.dart`: "Restore unsaved changes?" with the longest name | `test/flows/relink/recovery_test.dart` |
| Settings | `screens_overflow_test.dart`: editor settings, Auto captions on and off, scrolled through | `test/settings/editor_settings_screen_test.dart` |
| Home header | none (see below) | `test/editor_entry/home_edit_button_test.dart` (repo root) |
| Player top bar, Playback more sheet with "Edit video", shortcuts cheat sheet | none (see below) | `test/editor_entry/player_edit_action_test.dart` (repo root) |
| Licences | removed by the owner (UX-42 dropped); not in the matrix | none |

`coverage_manifest_test.dart` keeps this table honest. It fails if a mapped file disappears, if a mapped file stops using `testSurfaces`/`testOverflow`, or if the nightly script stops running the root entry tests.

**Home header and player.** These surfaces are in danaview_features. ARCH §4.2 rule 7 lets danaview_editor import only `chrome`, `orientation` and `storage` from that package, and the architecture test also scans test files, so this suite cannot render them. Their overflow tests are owned by UX-03 and UX-41 at the repository root. They cover 280–1280 px at 1.35 (Home) and 280×560 / 560×280 at 1.35 (player), not the full 84-surface matrix. The nightly script runs them. Extending them to the full matrix is a follow-up for their owners.

## Running it

```sh
# PR subset (what flutter-packages CI runs; the suite is untagged, so it is never excluded)
cd packages/danaview_editor && flutter test test/overflow

# Full matrix, nightly: QA-09 suite + every per-ticket matrix test + the root entry tests
scripts/ci/editor/nightly.sh overflow_full
scripts/ci/editor/nightly.d/overflow_full.sh            # the same, directly
scripts/ci/editor/nightly.d/overflow_full.sh --suite    # only test/overflow/
scripts/ci/editor/nightly.d/overflow_full.sh --root     # only the Home/player tests
```

**Reproducing a failure with one command.** On failure, the script prints one command per failing test, for example:

```sh
scripts/ci/editor/nightly.d/overflow_full.sh --name 'editor with every inspector panel [280x500 @1.35 android]' test/overflow/editor_inspector_overflow_test.dart
```

`--name` passes `--plain-name` to `flutter test`. Each test name carries its surface, so the command runs exactly that test. `--surface '<name>'` (`--dart-define=DANAVIEW_OVERFLOW_SURFACE=…`) narrows every test/overflow test to one surface. The failure message lists every problem of the test with its state, for example `[volume] exception: …` or `[overlay add] DanaviewButton label "…" is truncated`.

Logs go to `packages/danaview_editor/build/overflow_full/`. `OVERFLOW_JOBS` sets parallel test files (default 2, because the matrix is memory-heavy).

## Known defects

A problem that matches an entry in `knownDefects` (`test/overflow/overflow_rig.dart`) prints as `KNOWN DEFECT <id>` and does not fail the run. `--strict` (or `OVERFLOW_STRICT=1`) makes these entries fail too, the same convention as `core_fuzz.sh`'s `CORE_FUZZ_STRICT`. Remove an entry when its fix lands. Ids are shared with QA-08's register (`docs/v1.1/editor/qa/QA-08-a11y.md` §4, `test/a11y/a11y_support.dart`): one id names one defect in both suites. FIX-UX-22-1 there is the unlabeled preview-overlay node and FIX-UX-22-2 is this crash.

| Id | Owner file | Problem | Found by |
|---|---|---|---|
| FIX-UX-22-2 | `lib/src/editor/preview/manipulation_overlay.dart` (UX-22) | Selecting an audio clip (music or voice: a `MediaClip` with no `visual`) throws `ArgumentError: property "transform.scale" does not apply to this item` while building `ManipulationOverlay`. `_transformOf` evaluates `PropertyKeys.scale`/`rotation` on every selected non-cue item, including audio clips. This also breaks the Volume and Fades panels of an audio clip whenever the preview is shown. It reproduces on every surface where the preview region is visible. | `editor_inspector_overflow_test.dart` ("selected it_ovmusic0001", "volume", "fades") |

## Other findings (not known-defect entries: they fail the nightly until fixed)

These came from the first full-matrix run of the per-ticket matrix tests (`overflow_full.sh`, 2026-10-15). They are filed as FIX tickets in `docs/v1.1/editor/handoff/BUILD_STATE.md` ("Open FIX tickets filed by QA").

| FIX ticket | Test | Finding |
|---|---|---|
| FIX-UX-12-3 (UX-12) | `test/timeline/gestures/timeline_view_matrix_test.dart` at 412×915 @1.35 (with and without the keyboard) | After multi-select plus a selection ("1 selected"), a `RenderFlex` overflows by 75 px on the right with the test font. With the real Figtree font the same state fits on all 84 surfaces (QA-09 covers it in "editor idle and with each item kind selected"), so this is a test-font artifact. The row still has no flexible or ellipsizing child, so wider text (fallback scripts) would overflow. Fails only on the full matrix. |
| FIX-UX-14-3 (UX-14) | `test/transport/transport_bar_test.dart` "priority row actions that no feature binds yet (marker, snapping, ripple) are not shown" | Fails on every run, not only on the full matrix. The test expects an action to be unbound, but a feature binding now provides it (`Expected: null, Actual: Closure`). The test is out of date. |
| FIX-UX-18-1 (UX-18) | `test/preview/surface/preview_region_test.dart` "statuses offline media at the playhead: Media missing with Relink…" | Fails on every run. An icon the test expects to be absent is present. |

## Results

| Run | Command | Result |
|---|---|---|
| PR subset (6 surfaces) | `cd packages/danaview_editor && flutter test test/overflow` | 82 tests passed (2026-10-15) |
| Full matrix, QA-09 suite (84 surfaces) | `scripts/ci/editor/nightly.d/overflow_full.sh --suite` | 1018 tests passed. 288 `KNOWN DEFECT FIX-UX-22-2` lines; this run fails with `--strict` until UX-22 is fixed (2026-10-15) |
| Full matrix, per-ticket matrix tests | `scripts/ci/editor/nightly.d/overflow_full.sh` (part 2) | Fails: the UX-12, UX-14 and UX-18 findings above (2026-10-15) |
| Home header and player (repo root) | `scripts/ci/editor/nightly.d/overflow_full.sh --root` | 32 tests passed (2026-10-15) |
