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
