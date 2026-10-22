# S2 · Photos & Files Home: gate report

Slice S2 of 1.2.0 (BUILD_PLAN v1.2 §1A). The gate has three tickets: S2-W (wiring and legal,
§Wiring below), S2-Q (slice QA, the sections it adds below §Wiring) and S2-R (release candidate).
S2-W edits only §Wiring.

## Wiring

Ticket **S2-W**, Mac lane, on `v1.2-wip`, 2026-10-22. No feature work: the S2 feature tickets'
widgets and providers are composed at the app root behind `DANAVIEW_FILES_HOME` (default false,
never flipped in code). Integration rights: the slice's share of INT-103 (app root, router, root
pubspec) and of INT-106 (privacy and terms text).

### Files

| File | Change |
|---|---|
| `lib/wiring/files_home_wiring.dart` (new, `// OWNER: S2-W`) | The whole S2 composition: start-up overrides, the Home with its slots, opening library items, the Settings section |
| `lib/main.dart` (`// EXTENDED: S2-W`) | Adds `filesHomeOverrides(prefs:)` to the root `ProviderScope`; none with the flag off |
| `lib/router/app_router.dart` (`// EXTENDED: S2-W`) | Home route builds `appHomeScreen(…)` (the 1.1 `DanaviewHomeScreen` with the same arguments when the flag is off); `appSettingsSections` becomes a getter that adds Library storage only with the flag on |
| `pubspec.yaml` | Path dependencies `danaview_library`, `danaview_library_native` (already transitive; the app root now opens the store and adapts the native backup flag) |
| `packages/danaview_features/lib/src/more/legal_texts.dart` (`// EXTENDED: S2-W`) | S2 privacy and terms text, included only in builds with the flag (below) |
| `test/v12/wiring/s2_wiring_test.dart`, `test/v12/legal/s2_files_home_text_test.dart` (new) | Gate tests |

### What is wired (flag on)

| S2 feature | Where it is reached | Status |
|---|---|---|
| Library store (HOM-17) | Opened at start-up under `<appSupport>/DanaviewLibrary` (Android `filesDir/library`, ARCH §5.2) with `NativeBackupFlagPort` over HOM-02's `NativeBackupFlags` (Apple: `imports/` excluded); the Recently deleted sweep runs on open, daily while in the foreground, once on every resume, paused in the background. A store that fails to open is left out (Home keeps its 1.1 sections; library tabs show their empty states) | done |
| Thumbnails (HOM-04) | `openThumbnailService` under the cache directory, backup-excluded, trimmed on memory pressure; failure leaves placeholders | done |
| Home shell, 1.1 layout preserved (HOM-05…HOM-08) | `/` builds `FilesHome` → `DanaviewHomeScreen` with tabs Home, All, Videos, Photos, Playlists, Folders (+ Projects where the editor is reachable, opening the v1.1 `/projects`) | done |
| All / Videos / Folders tabs, Recently deleted (HOM-18) | `libraryFilterTabSlots`; All rows get Rename / Move / Delete through HOM-22's runner; Documents tab hidden (`documentsFilterShown = false`, S3) | done |
| Photos tab, viewer, EXIF (HOM-10, HOM-11) | Photos slot; tap opens `openPhotoViewer` over the tab's list; viewer Share hook over HOM-22's file-out port where the platform shares; Edit stays hidden (`onEditPhoto` is INT-105) | done |
| Badges (HOM-13) | Drawn by the tabs themselves | n/a (no wiring) |
| Recent photos tray (HOM-09) | Overview slot; See all and other tab requests re-open the shell on the requested tab (see defect D-1) | done |
| Selection bar (HOM-12, HOM-22) | `selectionBar` slot; groups `[mediaSelectionGroup, fileSelectionGroup]`; long press on a photo selects it, tap toggles while selecting. Make video montage and Batch edit stay hidden (INT-105) | done |
| Favourites, recents, search, sort (HOM-19) | Overview: search field (hits open the entry, switch to Folders/Photos for folder/system hits, play linked videos, open the linked folder for other linked files), Favourites row, Recents section; named sorts in SharedPreferences (`PrefsSortPreferenceStore`) | done |
| Import (HOM-20) | Overview "Import" button → `showImportSheet`; `NativeImportPicker` + `NativeImportCopier` on iOS, macOS, Android; `file_selector` picker on Windows and Linux; staging under `<cache>/danaview/import_staging` (swept on start) | done |
| File actions, getting files out (HOM-22) | Row menus and the selection bar; with no viewer in S2 a document, audio or other file opens its file menu (Open in another app, Share, Save out, File info); Windows and Linux get `DesktopFileOut` over `file_selector` and the default-app launcher | done |
| Desktop photo discovery (HOM-03) | Self-wired by its providers (no app-root input) | n/a |
| Settings › Library storage (HOM-17) | `appSettingsSections` adds `buildLibraryStorageSettingsSection` after Privacy | done |

**Not wired in S2** (later slices, entry points hidden, not disabled): Edit photo, Batch edit, Make
video montage (INT-105, S8); viewer router and document viewers (HOM-23…HOM-26, S3); Open with and the
Share Extension (HOM-21, INT-104, S3); Search with AI (S7); Merge into PDF (`mergeIntoPdfHandlerProvider`
stays null, S4).

### Flag set of the S2 build

- S2-R passes `--dart-define=DANAVIEW_FILES_HOME=true`, plus the v1.1 release defines
  (`DANAVIEW_EDITOR`, `DANAVIEW_AUTO_CAPTIONS`, v1.1 release checklist §3.2/§3.3). `DANAVIEW_PHOTO_EDITOR`,
  `DANAVIEW_BEAUTY`, `DANAVIEW_AI_STUDIO` stay off.
- `documentsFilterShown` (HOM-18) stays `false` until S3.
- With the flag off the app is the S1 app (pinned by `s2_wiring_test.dart` "flag off", INT-101's
  `flags_off_test.dart`, the S1 wiring test and HOM-15's suite).

### Privacy policy, terms and licences

`legal_texts.dart` gets constant blocks that join the documents through `if (FeatureFlags.filesHome)`
(a compile-time constant), so a build without the Home never describes it:

- **What Danaview stores on your device:** Danaview folders (imports are copies, originals never
  changed; app-private, not shown in other apps), the library database (names, sizes, dates,
  favourites, last 50 opened, sort choices, photo details read from the files), Recently deleted
  (30 days, still uses storage), thumbnails (cache, not backed up); a **Backups** paragraph: Apple
  device and iCloud backups include the library (unfinished imports excluded); Android device backups
  include it but cloud backup stops at 25 MB per app, so a larger app skips its cloud backup and the
  library moves only by phone-to-phone transfer; computers: part of any backup of the app's data folder.
- **Files and permissions:** photo library on the Home (only after "Show my photo library", limited
  and partial access honoured, read-only, the picker needs no access); Pictures folders on computers
  (read-only); saving and sharing always hand over a copy, shares are temporary.
- **Your choices:** Recently deleted Restore / Empty now and Settings › Library storage; Clear under
  Recents; photo access in system settings; uninstalling (or clearing storage on Android) deletes the
  Danaview folders.
- **Terms of Use:** new section "Danaview folders" (imports are copies; Empty now and the 30-day purge
  are permanent; uninstalling removes the folders; keep your own backups).
- **Licences:** no new entry. S2 bundles no third-party native code (PhotoKit, MediaStore, Quick Look
  thumbnailers are system frameworks; SQLite is the platform's); the new pub packages (`sqlite3`,
  `crypto`, …) reach Settings › About › Open-source licences through Flutter's generated NOTICES.
- `legalEffectiveDate` is left to S2-R with the owner (as in S1).

### Store-answer deltas (for S2-R and AIS-41)

| Store item | S2 delta |
|---|---|
| App Store App Privacy | No new data type collected: the library, database, thumbnails, favourites and recents stay on the device; photo library access is read on device only. Label unchanged by S2 (M-Lab reading from S1 still pending, Q-S1) |
| App Store review note | "The Photos tab can show the user's photo library only after they choose *Show my photo library*; importing uses the system pickers, which need no access. Limited access is honoured." |
| iOS `NSPhotoLibraryUsageDescription` (needed before S2-R; INT-104 owns `Info.plist`) | Proposed: "Danaview shows your photos and videos in the Photos tab when you choose Show my photo library. It only reads them." Same string for macOS `Info.plist` plus the `com.apple.security.personal-information.photos-library` entitlement (INT-104) |
| Google Play Data safety | No data collected or shared; unchanged by S2 |
| Google Play Photo and Video Permissions declaration | New if the app declares `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` for the Photos tab: Play requires the declaration form (core use: media player and gallery) or the app must rely on the Photo Picker alone. Owner decision needed before the S2 Play upload |
| Android backup | `library/` is in device transfer and cloud backup today (no exclusion); see defect D-3 |

### Tests (S2-W)

`test/v12/wiring/s2_wiring_test.dart` (20 tests, green plain; 19 + 1 skipped with
`--dart-define=DANAVIEW_FILES_HOME=true`), booting `DanaviewApp` with the real router over an
in-process HOM-17 fixture library:

- flag off: `filesHomeOverrides` adds nothing and never opens the library; Home is the 1.1 Home (no
  tab strip, Open file present); Settings shows Privacy and no Library storage;
- flag on, runtime: the store opens at `libraryRootIn(support, appSupport)` (`…/library` on Android);
  store, import service, native picker and copier, staging dir, prefs sort store, selection groups
  `[media, files]`, viewer share hook and `NativeFileOut` are installed; Linux gets the callback
  picker and `DesktopFileOut`; a failing store or thumbnail cache is left out; entries map to
  `PhotoMediaItem` / `VideoMediaItem` / `DocumentItem`;
- flag on, app: tabs Home, All, Videos, Photos, Playlists, Folders and no Documents; Overview keeps
  the 1.1 quick actions and shows Import and search; All lists the seeded photo, video and PDF; tapping
  the PDF opens its file menu and File info; Folders shows Danaview folders and Recently deleted; a tab
  request switches the shell to Photos; Import opens the import sheet; Settings shows Library storage
  after Privacy with the Android backup note;
- overflow: Home (Import ≥ 44 px), All, Folders, Photos and Settings at 280, 375, 1280 px × text scale
  0.85 and 1.35 with no exception.

`test/v12/legal/s2_files_home_text_test.dart` (6 tests, green plain and with the flag): content of
every block, no host named, and the blocks are in the policy and terms exactly when the build has the
flag.

Also run green: `test/v12/wiring` (S1 + S2), `test/v12/legal`, `test/v12/int101`,
`test/widget_test.dart`, `test/home_screen_test.dart`, `test/settings_account_test.dart`,
`test/editor_routes_test.dart`, `test/editor_wiring_test.dart`, `test/privacy_policy_host_test.dart`,
`test/editor_entry/legal_texts_test.dart` (304 tests; the legal tests also with the flag), and HOM-15's
`test/v12/preservation/suite_test.dart` (401 tests). `test/architecture/dependency_rules_test.dart`
fails only on rule 30 in HOM-04's Swift test (D-5, not an S2-W file). `flutter analyze --fatal-infos`
on `lib`, `test/v12/wiring`, `test/v12/legal` and `packages/danaview_features`: no issues.

Re-audit 2026-10-22 (resume): all of the above re-run green (S2 wiring and legal plain and with the flag;
the plain app tests 163; `test/v12/preservation` 528), analyzer clean. `test/v12/wiring/s1_wiring_test.dart`
pins the S1 flag set, so it runs plain only: with `DANAVIEW_FILES_HOME=true` its three "flags default to
false" / "exactly the S1 section" checks fail by design (Library storage is then present).

Device checks — the install-and-smoke of the flag-on build on the iOS Simulator and Android
Emulator, the first-run library open (`sqlite3` against the platform SQLite) and the photo library
prompt — are **deferred: no device available** to S2-Q / S2-R. S2-W ran widget tests only.

### Defects and open items

| # | Item | Owner | Status |
|---|---|---|---|
| D-1 | The Home shell keeps its selected tab private and does not listen for HOM-09's `HomeTabRequestNotification`, so See all (and any tab request) has no effect inside `DanaviewHomeScreen`. S2-W works around it by re-opening the shell on the requested tab (keyed rebuild; other tabs' scroll and folder positions reset) | HOM-05 | defect (workaround in place) |
| D-2 | `ios/Runner/Info.plist` has no `NSPhotoLibraryUsageDescription`: asking for photo library access from the Photos tab terminates the app on iOS. macOS needs the same string and the photos entitlement. INT-104 owns both and is listed under S3; S2-R needs this part first | INT-104 (FIX before S2-R) | **blocks S2-R** |
| D-3 | Android: `android/app/src/main/AndroidManifest.xml` declares `READ_MEDIA_VIDEO`/`READ_MEDIA_AUDIO` but not `READ_MEDIA_IMAGES` or `READ_MEDIA_VISUAL_USER_SELECTED`, so the Photos tab can't show the system photos on Android 13+. The backup rules include `filesDir/library/` in cloud backup: per CORE-28's own note, an app over the 25 MB quota fails the **whole** cloud backup (player data and profile included), not only the library; HOM-17's Settings note says only "a larger library is not in the cloud backup". ARCH §5.2 [VERIFY: HOM-17] should decide whether `library/` leaves `cloud-backup` (device transfer only) | INT-104, HOM-17, ARCH | defect |
| D-4 | No ticket places the import entry point or the search field on the Home (HOM-20's sheet and HOM-19's field have no host). S2-W puts an Import button and the search field at the top of the Overview's Recent photos slot as the S2 placement | HOM-05 / owner (placement) | open |
| D-5 | `test/architecture/dependency_rules_test.dart` rule 30 fails on `packages/danaview_library_native/darwin/Tests/Thumbnails/Core/ThumbnailCoreTests.swift:186` (a non-literal log in HOM-04's XCTest) | HOM-04 | defect |
| D-6 | The features barrel exports none of the Files & Media Home surfaces, so `lib/wiring/files_home_wiring.dart` imports `package:danaview_features/src/...` under `ignore_for_file: implementation_imports`. A public entry (for example `package:danaview_features/files_home.dart`) would remove that | INT-101 (barrel) | open, low |
| D-7 | Android SQLite for `library.db` (`sqlite3` 2.x needs a `libsqlite3.so` on Android, V-S21): if it is missing the wiring leaves the store out and the Home runs without Danaview folders. To be confirmed on the emulator | HOM-17 / Windows lane | open (deferred: no device available) |
| — | `legalEffectiveDate`, the owner's review of the S2 wording, regenerating the hosted privacy page **from a build with the flag** (the S2 text exists only there), the Play photo-permission declaration | S2-R with the owner | open |

## Slice QA

Ticket **S2-Q**, Mac half, on `v1.2-wip`, 2026-10-22, 07:20–08:50 (tree at `5b1ebe8`, then the
backup commits `16f79b9` and later that only added S2-Q's own files). QA changed no product code;
every defect below is a FIX ticket that blocks the gate. The Android Emulator half runs on the
Windows laptop.

**Re-run 2026-10-22, 10:16–11:15 (resume, tree at `2aafc88`).** Since the first run HOM-02 / HOM-04 /
HOM-20 / HOM-22 landed fixes (placeholder lists, the rule-30 measure test, move-rename rollback,
selection-bar padding, Recent photos tray, Photos tab facts) and S2-W changed the cache root. Everything
below was re-run on that tree; the tables carry the re-run numbers. **FIX-S2Q-1 and D-5 are closed.**
FIX-S2Q-3 and FIX-S2Q-5 are still open (no `setMeta` caller; `E2eApp._boot` unchanged), so the verdict
stays red. New: FIX-S2Q-6 (low, flaky RSS test) and the S2 Home stress probe (§2a).

**Gate verdict (Mac half): red** until FIX-S2Q-3 and FIX-S2Q-5 land and §3 batch 2 is re-run on the
wired library (FIX-S2Q-2, FIX-S2Q-4 and FIX-S2Q-6 are low; D-2 still blocks S2-R). The full v1.1 iOS
suite passes with the flags off, HOM-15 is green and bites, the native and Dart package suites, the
architecture test, the matrix, the persistence checks, the network guard and the stress probe are
green, and the S2 E2E passes every step except the photo details (FIX-S2Q-3).

### 1. S2 packages and suites

| Package / suite | Command | Analyze | Tests |
|---|---|---|---|
| `danaview_library` (HOM-16, HOM-17, HOM-19, HOM-20, HOM-22 Dart), `danaview_search`, core photo tests | `scripts/ci/v12/library.sh` | clean | re-run: 267 pass, **1 fail**: `import_memory_test` "2048 MiB import keeps memory flat" (RSS +76.9 MB, limit 64) while `property_test` runs in the same VM. Alone 3/3 pass, `dart test -j 1` 268 pass (FIX-S2Q-6, low); search 4 and core 14 pass |
| `danaview_library_native` (HOM-02, HOM-04, HOM-20, HOM-22 Dart side) | `flutter analyze --fatal-infos && flutter test -j 2` | clean | re-run: 22 pass (FIX-S2Q-1 fixed) |
| `danaview_library_native` XCTests, macOS runner | `darwin/Tests/<X>/run_xctests.sh macos` | — | re-run: PhotoLibrary 26 (10 skipped: PhotoKit, no TCC for a CLI runner), Thumbnails 34 (5 skipped), Pickers 20, ExportOut 26: all pass, no hang (FIX-S2Q-1 fixed) |
| `danaview_features` | `flutter analyze --fatal-infos` | clean | (tests live in root `test/v12`) |
| Root analyze | `flutter analyze --fatal-infos lib test/v12 test/architecture integration_test/v12 packages/danaview_features` | clean | — |
| Root `test/architecture` + `test/v12`, flags off | `flutter test -j 2 test/architecture test/v12` | — | re-run: 1186 pass, 2 skip, 0 fail (rule 30 green, D-5 fixed) |
| Root `test/v12`, `DANAVIEW_FILES_HOME=true` | `flutter test -j 2 --dart-define=DANAVIEW_FILES_HOME=true test/v12` | — | re-run: 1083 pass, 1 skip, 9 fail, all of them flags-off assertions (`int101/flags_off_test.dart` 6, `wiring/s1_wiring_test.dart` 3) that don't skip themselves when built with the flag (not product defects; see note N-2) |
| S2-Q's own tests (`test/v12/s2_qa/`, below) | `flutter test -j 1 test/v12/s2_qa`; again with the flag define | clean | 14 pass; 14 pass |
| HOM-15 preservation suite (merge gate) | `scripts/ci/v12/home_preservation.sh -j 1`; again with `--dart-define=DANAVIEW_FILES_HOME=true` | — | re-run: 406 pass; 406 pass |
| HOM-15 gate bites | `scripts/ci/v12/home_preservation.sh --self-check -j 1` (scratch copy, planted "Continue Watching") | — | re-run: OK, the planted regression fails the suite (18 tests) |
| v1.1 root tests that S2 touches | `flutter test -j 1 test/widget_test.dart test/home_screen_test.dart test/settings_account_test.dart test/editor_routes_test.dart test/editor_wiring_test.dart test/privacy_policy_host_test.dart test/editor_entry/legal_texts_test.dart test/network_tools_test.dart` | — | flags off: 174 pass (re-run). With the flag: 161 pass, 13 fail in `widget_test` / `home_screen_test` (duplicate "Folders"/"Playlists" texts from the tab strip, a second `EditableText` (search), the pinned header 107 px instead of 47): these are 1.1 layout tests of the flag-off Home; the flag-on Home is HOM-15's job (N-2) |

### 2. S2 E2E on the iOS Simulator (new scenarios)

`integration_test/v12/s2/s2_files_home_test.dart` (new, `// OWNER: S2-Q`), media generated locally by
`integration_test/v12/s2/tool/make_s2_media.sh` into `build/e2e/s2_media/` (Pillow: a 2400 × 1600 JPEG
with EXIF make/model/lens/date/exposure/aperture/focal length/ISO; ffmpeg: a 4 s 1280 × 720 H.264 + AAC
clip). Nothing downloaded. Run:

```text
integration_test/v12/s2/tool/make_s2_media.sh
DV_E2E_IPHONE="iPhone 16" DV_E2E_IPHONE_RUNTIME="iOS 26.5" \
DV_E2E_EXTRA_DEFINES="DANAVIEW_FILES_HOME=true DV_S2_MEDIA=$PWD/build/e2e/s2_media" \
  scripts/ci/editor/e2e_ios.sh --target integration_test/v12/s2/s2_files_home_test.dart iphone
```

The scenario boots the app as `lib/main.dart` does, **including `filesHomeOverrides`** (real HOM-17
store under `Application Support/DanaviewLibrary` with the writer on its own isolate, HOM-04
thumbnails, HOM-20 import service, HOM-22 actions). Only the system UI an integration test can't
drive is replaced at the app's own seams: the import picker stages copies into the app's staging
directory exactly as PHPicker / UIDocumentPicker do (`stagedCopy`), and the file-out port records
what the app hands to the share sheet, Save to Files and Save to Photos. First run 08:46–08:49;
re-run on `2aafc88` 10:28–10:31 with the same result on every row (simulator booted by S2-Q for the
re-run and shut down afterwards):

| Step | Result |
|---|---|
| Home with the flag: tabs Home, All, Videos, Photos, Playlists, Folders; no Documents; the 1.1 quick actions and sections, Import and search | pass (screenshot `s2-01-home`) |
| Nested Danaview folders: Folders › New folder "Trips" › open › New folder "Japan"; path Trips › Japan | pass |
| Import: photo "From Photos" into Japan (sheet's Save to chooser), video "From Files" into Imported; library copies byte-equal to the originals; staged copies deleted | pass (86 741 B, 1 646 405 B) |
| Organise: All › video › Move to… › Trips | pass |
| Viewer: Photos tab › tap the photo opens the viewer with its name | pass |
| **Viewer File info shows the EXIF** (camera, date taken, dimensions) | **fail**: rows are only Name, Size, Format, Source, Added from, Added, Modified (FIX-S2Q-3; checked softly so the scenario goes on, failed at the end) |
| Share from the viewer hands over the library photo (`image/jpeg`, bytes equal) | pass |
| Video opens from All in the player and plays (duration 4021 ms, position advances) | pass |
| Selection bar: long press › Save to Files (toast "Saved a copy"), long press › Save to Photos (toast); the library file unchanged | pass |
| Delete photo and video (All › Delete › confirm); Recently deleted lists both; Restore the photo → back in Trips › Japan | pass |
| Library closed and reopened (the store half of a restart): folders, entries, Recents, Recently deleted persist; restore the video → Trips; every live entry's file present | pass |
| Originals: bytes and timestamps unchanged | pass |
| Network: HttpOverrides spy for the whole scenario, no `HttpClient` created | pass |

Result: **1 file, fails only on FIX-S2Q-3.** Evidence: `build/e2e/ios/6663101E-6BE7-47D4-B3B8-055700BF2E02/s2q_evidence/`
(9 screenshots, the test log with the `DV_E2E_REPORT s2:` lines).

### 2a. S2 Home stress probe (S2's share of HOM-14)

`integration_test/v12/s2/s2_home_stress_test.dart` (new, `// OWNER: S2-Q`; HOM-14 owns the 50,000-item
run). On the real S2 wiring it generates 5,000 Danaview-folder items through the import path (60 %
photos, 25 % videos, 15 % text, with photo/video facts; sources from `make_s2_media.sh stress/`), then
flings (3 down, 2 up) and drags (8 slow) All, Videos, Photos and a 4,000-item folder, recording every
`FrameTiming`, RSS and the HOM-04 cache, and leaves the library as found. The first attempt (09:26)
failed to load (`vm_service` "client closed with pending request", a tool flake); the re-run
10:32–10:34 passed:

| Tab | fling: frames, build p90 / p99, build+raster > 8 ms, spans > 2 frames | drag: same | thumb LRU peak (cap 64 MB), evictions, generated / disk hits |
|---|---|---|---|
| All | 651, 7.8 / 18.0 ms, 84, 7 | 582, 3.9 / 6.7 ms, 10, 0 | 34.5 MB, 0, 208 / 0 |
| Videos | 658, 6.6 / 10.3 ms, 58, 0 | 576, 2.0 / 7.9 ms, 17, 0 | 64.0 MB, 385, 232 / 43 |
| Photos | 655, 5.5 / 12.2 ms, 28, 7 | 582, 2.3 / 4.8 ms, 2, 1 | 64.0 MB, 490, 344 / 133 |
| Folders (big folder) | 654, 5.4 / 8.7 ms, 22, 1 | 589, 4.1 / 6.7 ms, 9, 0 | 64.0 MB, 62, 247 / 0 |

Seeding 5,000 entries took 7.5 s; Home with tabs 702 ms after the pump; first frame after a tab tap
478–708 ms; RSS max 430 MB, back to 154–182 MB after each tab; no thumbnail failures, no exception.
The LRU never exceeds its 64 MB cap. The simulator runs a **debug (JIT)** build only (no profile mode
on the iOS Simulator), so the frame numbers are indications, not the ARCH §10.1 verdict, which is
HOM-14 / QA-104 on the device lab: deferred: no device available.

Real Save to Photos was also tried (`DV_S2_REAL_PHOTOS=true` after `simctl privacy grant
photos-add`): `flutter test` reinstalls the app, the grant is gone, and iOS shows the add-only prompt,
which a Flutter test can't answer; the run timed out at that prompt (screenshot
`s2-save-to-photos-prompt.png`). The prompt itself shows the 1.1 usage string "Danaview saves the
videos you export to your photo library." (FIX-S2Q-4). The real share sheet, UIDocumentPicker export
and PHPicker need a person: deferred: no device available (manual simulator check for S2-R).

Not driven in E2E, covered by widget tests: Recently deleted expiry (fake clock, §4), the photo
library permission flow ("Show my photo library" would hit D-2), favourites and search UI (HOM-19).

### 3. Full v1.1 suite on the iOS Simulator, flags off and on

`scripts/ci/editor/e2e_ios.sh iphone`, `DV_E2E_IPHONE="iPhone 16"`, `DV_E2E_IPHONE_RUNTIME="iOS 26.5"`,
models read in place from `/Users/besaoct/danaview-models` (nothing downloaded). The script passes the
v1.1 release defines `DANAVIEW_EDITOR=true`, `DANAVIEW_AUTO_CAPTIONS=true`.

| Batch | 1.2.0 defines | Started / ended | Result |
|---|---|---|---|
| 1 · every 1.2.0 flag off | none | 07:25 / 07:58 | **20 of 20 files pass** (s01–s18, `x_android_api28`, `x_ios_background_export`; `x_android_export_background` skipped on iOS as designed) |
| 2 · S2 flag set | `DANAVIEW_FILES_HOME=true` (via `DV_E2E_EXTRA_DEFINES`, confirmed on the running `flutter test` command line) | 08:14 / 08:42 | **partial**: 20 of 20 files pass, but against the new Home shell **without the S2 library** (no `filesHomeOverrides` in QA-00's boot, FIX-S2Q-5); to be re-run once FIX-S2Q-5 lands |

Simulator realities, reported not failed (both batches): HEVC/MOV not offered (`hevcEncode false`);
`pausedInBackground observed: false`; s13 start latency 267 / 233 ms (device budget 100 ms). s07 burned
cues 341 and 324 changed samples; s08 3 cues; s15 head -14.6 dBFS, body -9.0 dBFS. Logs and summary:
`build/e2e/ios/6663101E-6BE7-47D4-B3B8-055700BF2E02/`. The iPhone 16 simulator was already booted
(not by this ticket) and was left as found.

Batch 2 is **partial**, not a pass of the gate requirement. QA-00's `E2eApp._boot` mirrors
`lib/main.dart` step by step but not S2-W's `filesHomeOverrides`, so in the flag-on batch the Home is
the Files & Media Home **without** a library store: library tabs empty, the Overview's Import hidden,
no import service, no thumbnails. That is not the composition `lib/main.dart` ships in the S2 release
candidate, so "the full v1.1 suite re-run with the slice's flags on" (BUILD_PLAN §0 S<n>-Q) is only
partly met: the run proves the 1.1 flows survive the new Home shell, not that they survive next to
the wired library (store on its isolate writer, daily sweep, thumbnail cache and its memory-pressure
trim, import service). §2 covers the wired library for the S2 flows only. **FIX-S2Q-5 blocks the
S2-Q verdict**: once QA-00 adds `...(await filesHomeOverrides(prefs: prefs)).overrides` to
`E2eApp._boot`, batch 2 is re-run and this row replaced.

### 4. Persistence (QA-106 scope for S2)

`test/v12/s2_qa/s2_persistence_test.dart` (new, 4 tests, green) opens the library the way the app
does (`filesHomeOverrides` → `LibraryStore.open` with the isolate writer under `libraryRootIn(<support>)`):

- nested folders, a folder's sort, imported files (bytes), favourites, Recents and Recently deleted
  (days left 27 after 3 days) survive a close and reopen; restore after the restart returns to the
  folder; the original is unchanged (bytes and timestamp);
- Recently deleted expiry across restarts with a fake clock: still there after 29 days (1 day left),
  purged by the launch sweep after 31 days (row and files gone);
- a corrupt `library.db` is quarantined at the next start and the library rebuilt from the files
  (same entry id);
- backup classes: `library.db`, `files/` included; `imports/` excluded.

On the simulator the S2 E2E's reopen step passed (§2). Plus HOM-17's own crash, recovery, property and
expiry tests in `danaview_library` (§1). Named sorts live in SharedPreferences
(`PrefsSortPreferenceStore`, HOM-19 tests). iOS device backup / restore and Android device-to-device
transfer of Danaview folders: deferred: no device available.

### 5. Overflow and accessibility (QA-105 scope for S2)

`test/v12/s2_qa/s2_matrix_test.dart` (new, 10 tests, green) boots `DanaviewApp` with the app router and
the S2 wiring over a HOM-17 fixture library with very long names, nested folders, a trashed file, a
favourite and a recent, and visits: Overview (Import, search, Recent photos, Favourites, Recents),
import sheet, its folder chooser, All, an All row menu, a document's file menu, File info, Videos,
Photos, the Photos selection bar, the photo viewer, its info sheet, Folders root, a nested folder with
breadcrumbs, Recently deleted.

| Check | Sizes | Result |
|---|---|---|
| No exception (overflow) on every surface | 280, 375, 768, 1280 px × text scale 0.85, 1.35 | pass (8 runs) |
| `iOSTapTargetGuideline` (44 pt), `labeledTapTargetGuideline`, `textContrastGuideline` on every surface | 375 px × 1.0, 1280 px × 1.35 | pass (2 runs) |

The per-ticket matrices (HOM-05…HOM-13, HOM-18…HOM-20, HOM-22, HOM-17 Settings) and S2-W's composed
matrix are green inside the §1 counts. Custom components only (rule 31) is enforced by the
architecture test (green except rule 30). VoiceOver pass on the Home tabs and folder operations:
deferred: no device available (simulator VoiceOver not scripted).

### 6. Network guard (QA-103 scope for S2)

- S2 adds **no host**. Static scan of `danaview_library/lib`, `danaview_library_native/lib` and
  `darwin/Classes`, `danaview_features/lib/src/library`, `lib/wiring` for `HttpClient`, `package:http`,
  sockets, `URLSession`, `NSURLConnection`, `Uri.http(s)` and URLs: only Pigeon's generated comment and
  the 1.1 Open link hint.
- PhotoKit requests set `isNetworkAccessAllowed = false` everywhere (PhotoLibraryService, thumbnailer):
  iCloud-only originals are never downloaded (ARCH §9.1).
- HttpOverrides spies: none created in the S2 E2E on the simulator (§2) nor in the matrix flows (§5).
- Rule 21 (no sockets in library/native code) is in the green part of the architecture test.
- Device-level spy (QA-103's `integration_test/v12/network_spy/`): not built yet; deferred to QA-103.

### 7. Android Emulator half

pending: Windows

### 8. Defects (FIX tickets, block the gate unless marked low)

| Id | Owner | Defect | Evidence | Fix direction |
|---|---|---|---|---|
| **FIX-S2Q-3** | HOM-20 (import) with HOM-11 (viewer) | Danaview-folder photos never get their photo facts: nothing writes `entry_meta` on import (`LibraryWriter.setMeta` has no caller; `ImportService` commits without `meta`; no import hook reads EXIF), and HOM-11's File info reads only `EntryMeta` for Danaview photos. So imported photos show no Taken, Camera, Lens, exposure or Dimensions, and the Photos grid groups them by file date with width/height 0. The S2 result "photo grid and viewer with EXIF" (§1A) is not met for imported photos | §2 row "Viewer File info", log line `info rows: [name, size, format, source, imported, added, modified]` for a JPEG with full EXIF | An import hook (or the copier) reads EXIF and dimensions after the copy (ImageIO / `ExifInterface` through the native plugin, or a Dart EXIF reader) and calls `setMeta`; HOM-11 test with a real EXIF JPEG through the import path |
| FIX-S2Q-2 (low) | HOM-17 | `LibraryStore.checkInvariants()` throws with the isolate writer the app uses: its op closure captures `this` (`unavailable`), which holds the `ReceivePort` (`Illegal argument in isolate message: object is unsendable`). Only the in-process writer of the tests can run it, so the app and on-device QA can't check invariants | `s2_persistence_test` first draft; stack `LibraryStore.checkInvariants → _IsolateHost.run` | Copy `unavailable` into a local before building the closure (and add a test with `background: true`) |
| FIX-S2Q-4 (low) | INT-104 (`ios/Runner/Info.plist`) | `NSPhotoLibraryAddUsageDescription` is still the 1.1 text "Danaview saves the videos you export to your photo library.", but S2's Save to Photos saves photos and videos from Danaview folders | Simulator prompt screenshot (§2) | Reword (for example "Danaview saves copies of your photos and videos to your photo library when you choose Save to Photos.") together with D-2's `NSPhotoLibraryUsageDescription` |
| **FIX-S2Q-5** | QA-00 (`integration_test/editor/support/e2e_app.dart`) | `E2eApp._boot` does not add S2-W's `filesHomeOverrides`, so the v1.1 suite with `DANAVIEW_FILES_HOME=true` runs the new Home without the library (tabs empty, no Import, no import service, no thumbnails): not the shipped S2 composition, so §3 batch 2 is partial. **Blocks the S2-Q verdict** | §3 | Add `...(await filesHomeOverrides(prefs: prefs)).overrides` to the boot (nothing with the flag off), then S2-Q re-runs §3 batch 2 |
| FIX-S2Q-6 (low) | HOM-20 (`danaview_library/test/import/import_memory_test.dart`) | The "2048 MiB import keeps memory flat" test samples `ProcessInfo.currentRss` of the whole test VM, which `dart test` shares with the suites it runs concurrently; next to `property_test` the RSS grew 76.9 MB (limit 64) and `scripts/ci/v12/library.sh` failed. Passes alone (3/3) and with `-j 1` | §1 re-run | Run the test in its own process (a `@Tags(['rss'])` + separate `dart test -t rss` step in `library.sh`, or spawn the copy in a child process and sample its RSS) |
| ~~FIX-S2Q-1~~ | HOM-02 | **Closed** on the re-run: both placeholder lists now hold only Quick Look and Inbox (plus `documentThumbnail`); Dart 22 pass, PhotoLibrary XCTests 26 pass, no `NSSavePanel` hang | §1 | — |
| ~~D-5~~ (from §Wiring) | HOM-04 | **Closed** on the re-run: the HEIC miss test uses XCTest `measure` with no log call; rule 30 green | §1 | — |
| D-2 (from §Wiring) | INT-104 | No `NSPhotoLibraryUsageDescription`: "Show my photo library" terminates the app (not exercised in E2E for that reason) | §Wiring | blocks S2-R |

Notes (not defects):

- N-1: `Recents` drops an entry while it is in Recently deleted and shows it again after a restore
  (by design of `LibraryReader.recents()`).
- N-2: the v1.1 root widget tests, INT-101's `flags_off_test.dart` and S1-W's `s1_wiring_test.dart`
  assert the flag-off app and fail when the whole file is built with `DANAVIEW_FILES_HOME=true`; the
  flag-on Home is certified by HOM-15 (401 green with the define), S2-W's wiring test and §2/§5. Making
  those files skip themselves under the define (as S2-W's test does) would let a flag-on CI job run
  `test/` whole.

### Files added by S2-Q

| File | Purpose |
|---|---|
| `integration_test/v12/s2/s2_files_home_test.dart` | S2 E2E scenario (§2) |
| `integration_test/v12/s2/s2_home_stress_test.dart` | S2 Home stress probe (§2a) |
| `integration_test/v12/s2/tool/make_s2_media.sh` | Local test media (Pillow, ffmpeg), incl. the stress sources |
| `test/v12/s2_qa/s2_matrix_test.dart` | Composed overflow / a11y matrix and HttpOverrides guard (§5, §6) |
| `test/v12/s2_qa/s2_persistence_test.dart` | Persistence across restarts (§4) |
| `docs/v1.2/qa/S2-QA.md` | This section |
