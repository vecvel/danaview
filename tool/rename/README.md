# Vwish → Danaview rename

`rename_to_danaview.py` renames the app from Vwish to Danaview everywhere in the repository:
- file contents and file and folder names;
- packages, store and bundle IDs, the URL scheme and channel names;
- the editor project type (`.vwproj` → `.dnproj`);
- the `vw`/`VW` prefixes of the C ABI, macros, namespace, Swift/Metal/Dart types and tags;
- generated files and byte-exact fixtures, which it regenerates.

When the cutover is done, the repository holds no "vwish", "vw" or "VW" used as our name.

It runs **once, at cutover, on the latest `editor-wip`**, so it discovers everything from the
tree; there is no fixed file list. It needs only Python 3.8+ and the standard library. It is
deterministic and idempotent: a second `--apply` changes nothing.

`DRY_RUN_REPORT.md` is its `--dry-run` output for `editor-wip` at `ed79da9`. It contains:
- every change grouped by rule, with each distinct token's old name, new name and count;
- the KEEP list and the counts per file type;
- every folder and path rename;
- the regeneration list and the RECOMPILE list;
- the artwork list and the Mac checklist.

## Rules

Rules are case-preserving and applied in this order:

| # | Rule | Examples |
|---|---|---|
| 1 | Brand: `vwish`/`Vwish`/`VWISH` → `danaview`/`Danaview`/`DANAVIEW` anywhere, also inside words | `VwishColors`, `vwish_editor_core`, `vwish_player`, `com.vecvel.vwish` (applicationId, namespace, `com/vecvel/vwish` folders, bundle IDs incl. RunnerTests, fastlane, ExportOptions, CI, runner and installer metadata), `vwish://`, `"vwish/..."` channels, prefs keys and storage folders, local paths `…/vwish_player` |
| 2 | Project type: `vwproj`/`Vwproj`/`VWPROJ` → `dnproj`/`Dnproj`/`DNPROJ` | `.vwproj`, `VwprojFormat`, `vwproj_format.dart` |
| 3 | `vw_` → `dv_` at token start, at a snake segment start, after `lib` | `vw_job`, `_vw_job_startPtr`, `fake_vw_bindings`, `libvw_shim`, `vw_exports.map`, `vw_spike_kernels` |
| 4 | `VW_` → `DV_` in the same positions and after `-D` | `VW_OK`, `VW_ERR_*`, `TEST_RUNNER_VW_SECONDS`, `-DVW_SANITIZER` |
| 5 | Lone `vw` before `::`, before `.` + letter, after `namespace ` | `vw::`, `namespace vw`, `vw.spike.export`, `vw.cleanup.v1` |
| 6 | `Vw` + [A-Z0-9] at token start or after a lowercase letter; `vw`/`VW` + [A-Z0-9] at token start; the lone `VW` | `VwStatus`, `FakeVwBindings`, `VwT`, `vwAbiVersion`, `VWSpikeHost`, `VWEditorKernels`, `VWPK`, `VWT_CMP`, "VW Spike" |
| 7 | Tags `vwt`, `vwtest`, `vwspike`, `vwpk`, `vwth` at token start | `vwt::`, `vwt_support`, `.vwpk`, `.vwth`, `vwspike-media` |

**Classifier.** Before changing anything, every token matching `/[A-Za-z0-9_]*vw[A-Za-z0-9_]*/i`
in a text file is classified. Each "vw" inside it is either renamed by a rule above, or kept by
the KEEP list:
- `vW` inside ordinary words: `WavWriter`, `vWidth`, `avWithin40ms`, `CommandLineToArgvW`;
- random media and test ids `md_…` and `qh_md_…`;
- the alphabet strings;
- `dvwC` (MP4 Dolby Vision box);
- the local pair `(vw, vh)` (video width and height) in `regen_goldens.dart`.

**Any unclassified token stops `--apply`.** Code written after this script can't slip through:
add a rule or a KEEP entry, then rerun.

**Never edited:**
- `packages/*/third_party/**` (vendored whisper.cpp/ggml);
- `.git`, `build/`, `.dart_tool/`, `Pods/`, `.gradle/`, `.cxx/`;
- `android/key.properties`, `*.jks`, `*.keystore`;
- this folder (`tool/rename/`, removed at cutover);
- binary files;
- generated files and hashed fixtures (see "Regeneration" below).

**Binary scan.** `--verify` also scans binaries, but only flags real names that appear as
readable strings. In compressed media (PNG, JPG, MP4, MOV, MKV, WebM, M4A, WAV, JAR, TTF, ICO),
that means the brand, or a whole identifier of 7+ characters inside readable text. That way
compression noise (`Vw_`, `VWSA`, `vWEQ`) is never reported. The only binaries carrying our
names are the 4 spike metallibs.

**Targeted patch:** `spikes/ios_engine/tools/build_metallibs.sh` now does `cd "$HERE"` and
compiles from relative paths. The rebuilt metallibs then carry no absolute checkout path.

## Regeneration

Generated files and hashed fixtures are rebuilt with the repo's own tools, never edited.
`--regenerate` runs these steps in order. Steps marked "macOS" are skipped elsewhere, and a step
whose input no longer exists is skipped and reported.

| Step | Rebuilds | Command |
|---|---|---|
| Resolve packages | every `pubspec.lock`, plugin registrants | `flutter pub get` in the root and every package |
| Pigeon | `engine_api.g.dart`, `EngineApi.g.swift`, `EngineApi.g.kt` | `dart run pigeon --input pigeons/engine_api.dart` |
| ffigen (needs libclang) | `dv_whisper_bindings.g.dart` | `dart run ffigen --config ffigen.yaml`; without libclang (Windows) it writes the rule-mapped file and says PROVISIONAL, and the Mac regenerates it for real |
| Codec goldens | `test/codec/fixtures/*.body.json`, `kitchen_sink.dnproj` (SHA-256 changes) | `DANAVIEW_UPDATE_GOLDENS=1 dart test test/codec/determinism_test.dart` |
| Schema fixtures | `test/fixtures/projects/s0,s1/*.dnproj` (SHA-256 changes) | `REGENERATE_FIXTURES=1 dart test test/codec_migrations/fixtures_test.dart` |
| Sprites, **macOS** | `test_fixtures/sprites/*.vsprite` + `sprites.json` (the "Vwish" text sprite; Adler-32 changes) | `DANAVIEW_REGEN_SPRITE_FIXTURES=1 flutter test test/render_prep/sprite_fixtures_test.dart` |
| Reference goldens | `test_fixtures/vectors`, `test_fixtures/images` (expected: no change) | `dart run tool/regen_goldens.dart` |
| CocoaPods, **macOS** | `ios`, `macos` and `example/ios` `Podfile.lock` (checksums change) | `pod install` |
| **RECOMPILE ON MAC AT CUTOVER** | the 4 spike `.metallib` files + both `BUILD_INFO.txt` (SHA-256 changes) | `(cd spikes/ios_engine && bash tools/build_metallibs.sh)` |

**Why sprites are Mac-only.** On Windows the generator also rewrites sprites that never
contained the name, because Flutter's glyph rasteriser and zlib differ by host. The committed
sprites were made on the Mac. Regenerated there, only `text_box_stroke_shadow.vsprite` and its
`sprites.json` entry may change.

**Fixtures edited as text.** Every other fixture, golden or JSON vector that contains our names
is edited as text. They're safe to edit because the tests that compare each of them byte for
byte against its generator pass after the rename. These include:
- the `render_plans/contract` and `compile_*` goldens;
- the engine API plans, vectors and `goldens.json`;
- `frame_grid.json`, `quickhash_vectors.json` and the fuzz regressions;
- the architecture `*.fixture` files and the Kotlin lint `*.kt.txt` fixtures.

**Generated output checked on Windows.** The Pigeon output regenerated on Windows is
byte-identical to the old output with the rules applied. The lock files keep the same packages
and versions; only the order changes.

## Modes

```
python3 tool/rename/rename_to_danaview.py --dry-run [--report FILE]
python3 tool/rename/rename_to_danaview.py --apply [--allow-dirty]
python3 tool/rename/rename_to_danaview.py --regenerate
python3 tool/rename/rename_to_danaview.py --verify [--allow-mac-pending]
```

- `--dry-run` exits 1 when a token is unclassified or two paths would collide.
- `--apply` refuses to run on a dirty tree, and on unclassified tokens or collisions. It edits
  contents, applies the targeted patch, `git mv`s renamed files, then renames folders deepest
  first. Finally it prints the regeneration commands.
- `--verify` exits 1 if an old name remains in contents, paths or binaries outside the
  exclusions. On Windows, `--allow-mac-pending` tolerates the files only macOS can rebuild: the
  `Podfile.lock` files, `sprites.json`, `*.metallib` and `BUILD_INFO.txt`.

## Cutover

### Before you start (both machines)

1. Merge `editor-android` into `editor-wip`, and push all work from both machines. Every
   unmerged branch will have to be rebased onto the renamed tree, or redone on it.
2. Close the IDEs, simulators and emulators, and stop Gradle daemons. On Windows, close Explorer
   windows inside the repo so OneDrive or the IDE don't lock folders during `git mv`.

### On the Mac (does the rename)

1. **Rename the local folder first**: `mv ~/Desktop/vwish_player ~/Desktop/danaview_player`.
   Also move Claude's notes folder to match:
   `mv ~/.claude/projects/-Users-besaoct-Desktop-vwish-player ~/.claude/projects/-Users-besaoct-Desktop-danaview-player`.
2. Get the latest code and branch from it:
   ```
   cd ~/Desktop/danaview_player
   git checkout editor-wip && git pull
   git checkout -b danaview-cutover
   git checkout origin/rename-danaview -- tool/rename
   git commit -m "tool(rename): add the rename script"
   ```
3. Dry run:
   ```
   python3 tool/rename/rename_to_danaview.py --dry-run --report /tmp/rename_report.md
   ```
   The summary must say `Unclassified tokens: 0` and `Path collisions: 0`. If not, extend the
   rules or the KEEP list in the script, commit, and repeat.
4. Rename and regenerate:
   ```
   python3 tool/rename/rename_to_danaview.py --apply
   python3 tool/rename/rename_to_danaview.py --regenerate
   python3 tool/rename/rename_to_danaview.py --verify
   ```
   Run `--verify` **without flags**: on the Mac it must pass with nothing pending. Then
   `git status` must show:
   - only `text_box_stroke_shadow.vsprite` and `sprites.json` changed under
     `test_fixtures/sprites`;
   - no change to `dv_whisper_bindings.g.dart` after the real ffigen run (that proves the
     provisional mapping);
   - new metallibs. Check them: `strings spikes/ios_engine/DVSpike*/Prebuilt/*.metallib | grep -i -e vwish -e '/Users/'`
     must print nothing.
5. Work through the Mac checklist below, then run `flutter analyze`, the tests of every package,
   and the iOS/macOS builds.
6. Remove the tool, so nothing named after the old app remains, then commit:
   ```
   git rm -r tool/rename
   git add -A
   git grep -I -i -n vwish -- . ':!packages/*/third_party/**'   # must print nothing
   git commit -m "chore: rename Vwish to Danaview"
   ```
   Push `danaview-cutover`, then merge it into `editor-wip` (and `main` when due).
7. Outside the repo:
   - Rename the GitHub repo `vecvel/vwish` → `vecvel/danaview`, then run
     `git remote set-url origin https://github.com/vecvel/danaview.git` on both machines.
   - Publish the pages the URLs now point to: `vecvel.com/ios/danaview/privacy` and `/support`,
     `vecvel.com/danaview`, and `vecvel.com/schemas/danaview/*.schema.json`.
   - Create the App Store Connect and Play Console records for `com.vecvel.danaview`, plus the
     provisioning profiles, and rename the CI signing secrets if their names change.
   - Replace the artwork listed in the report under "Needs new Danaview artwork": app icons,
     branding, store screenshots, publishing assets.

### On the Windows laptop (after the Mac pushed)

1. Rename the folder `…\Desktop\vwish` → `…\Desktop\danaview_player`. Move Claude's notes
   folder `%USERPROFILE%\.claude\projects\C--Users-Masud-OneDrive---Zota-Healthcare-Ltd-Desktop-vwish`
   → `…-Desktop-danaview-player`. Also rename `~/vwish_env.sh` → `~/danaview_env.sh`, and its
   `VWISH_*` variables.
2. In the renamed folder: `git remote set-url origin https://github.com/vecvel/danaview.git`,
   `git fetch`, then check out the renamed `editor-wip`. Rebase any local branch onto it. A
   branch from before the rename should be rebuilt by re-running the script on it (see
   "Branches cut before the rename" below), not rebased by hand.
3. Delete stale caches left in old folder names (`build/`, `.dart_tool/`, `android/.gradle`).
   Then run `flutter pub get` in the root and every package, and `flutter build apk --debug`.

### Branches cut before the rename

To move a branch from before the cutover onto the renamed tree:
1. Check out the branch.
2. Add the tool: `git checkout <cutover commit>^ -- tool/rename`, so the version that ran.
3. Run `--apply` and `--regenerate`, and commit.
4. Merge the renamed `editor-wip`. Conflicts are then only real changes, not names.

## Tested on Windows (this branch)

Run on 2026-10-11 on `editor-wip` at `ed79da9`. The Windows laptop has Flutter 3.44.8, no
libclang and no Metal.

1. **Dry run:** 0 unclassified tokens and 0 collisions. It changes 14,497 places in 1,143 files,
   moves 2,111 paths and renames 60 folders.
2. **`--apply`, then `--regenerate`:** pub get, Pigeon, ffigen (PROVISIONAL), the codec goldens,
   the schema fixtures and `regen_goldens` (no change).
3. **`--verify --allow-mac-pending`:** OK, with 9 files pending on macOS: 2 `Podfile.lock`,
   `sprites.json`, 4 `.metallib` and 2 `BUILD_INFO.txt`.
4. **`flutter analyze`:** no issues in any of the 14 packages. The root's 7 issues also exist
   before the rename: 3 `prefer_const`, 2 errors in the spike `flutter_texture_latency`, and 2
   in `test/editor_entry`.
5. **Tests, per package:**
   - **No test fails because of the rename.** Every remaining failure also fails on the
     unrenamed tree on this laptop: the `test/store/**` file-system tests, the golden images,
     the Windows `dart` launcher used by `pigeon_regeneration_test`, and the network tests.
   - Three flaky core tests that failed in the baseline now pass.

   | Package | Passed | Failed (all pre-existing) |
   |---|---:|---:|
   | root | 432 | 4 |
   | danaview_data | 52 | 3 |
   | danaview_editor | 1503 | 37 |
   | danaview_editor_core | 3749 | 82 (baseline 85) |
   | danaview_editor_engine | 190 | 1 |
   | danaview_editor_engine_api | 406 | 1 |
   | danaview_transcription | 391 | 1 |
   | danaview_ui_kit | 306 | 0 |
   | danaview_whisper | 89 | 0 |
6. **`flutter build apk --debug`:** OK. aapt2 reports package `com.vecvel.danaview` and label
   `Danaview`.
7. **`flutter build windows --debug`:** OK, after installing Visual Studio Build Tools 2022
   (C++ workload) on the laptop. It produces `danaview.exe` with ProductName and FileDescription
   `Danaview`.
8. **Repeat from scratch** (`git checkout . && git clean -fd`, then the same cycle): the tree
   hash is identical (`cf50ca3`). Symlinks and executable bits are preserved.
9. **Second `--apply` on the renamed tree:** 0 edits and 0 moves (idempotent).
10. **Generated output checked against the old files:**
    - The Pigeon output regenerated on Windows is byte-identical to the old output with the
      rules applied.
    - The `pubspec.lock` files keep the same packages and versions; only the order changes.

## Mac checklist (could not be verified on Windows)

- Rename the checkout folder (…/vwish_player -> …/danaview_player) before anything else, and move Claude's notes folder to match (~/.claude/projects/-Users-besaoct-Desktop-vwish-player -> …-danaview-player).
- --regenerate on the Mac: pod install (ios, macos, editor engine example), the .vsprite fixtures (only text_box_stroke_shadow may change), ffigen for real (no diff expected), RECOMPILE the 4 spike metallibs; then `--verify` with no flags must pass.
- Metal: the renamed kernels (dv_look, dv_blur_h/v, dv_sharpen, dv_look_st, dv_blur_h_st, ...) and their Swift lookups in DVSpikeKernels/DVSpikeStitchable; `strings *.metallib | grep -i -e vw -e /Users` must be empty.
- Podspecs: danaview_whisper, danaview_editor_engine (resource bundle DVEditorKernels), the spike pods DVSpikeKernels and DVSpikeStitchable; `pod lib lint` or a clean `pod install`.
- Swift: the editor engine plugin (Pigeon output, DVPK waveforms, DVTH thumbnails, DVEditorKernels loader), danaview_whisper (dv_whisper_forwarder.cpp, DynamicLibrary.open('danaview_whisper.framework/danaview_whisper'), os_log subsystem com.vecvel.danaview.whisper).
- Xcode projects: PRODUCT_BUNDLE_IDENTIFIER com.vecvel.danaview and com.vecvel.danaview.RunnerTests (ios, macos, example), danaview.app / TEST_HOST, schemes, ExportOptions.plist, entitlements, CFBundleURLSchemes danaview, CFBundleURLName.
- Builds and tests: flutter build ios --debug --no-codesign, flutter build macos --debug, the example app's RunnerTests (XCTest), the whisper host tests (src/tests, dv_test.h) with DV_SANITIZER.
- The spike host app (DVSpikeHost, DVSpikeTests, DVSpikeUITests): builds, Info.plist name "DV Spike".
- fastlane: deliver/supply dry runs with the new Appfiles and metadata; new App Store and Play records for com.vecvel.danaview.
