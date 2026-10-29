# S3 · Documents: view and share-in: gate report

Slice S3 of 1.2.0 (BUILD_PLAN v1.2 §1A). The gate has three tickets: S3-W (wiring and legal,
§Wiring below), S3-Q (slice QA, the sections it adds below §Wiring) and S3-R (release candidate).
S3-W edits only §Wiring.

## Wiring

Ticket **S3-W**, Mac lane, on `v1.2-wip`, 2026-10-23. No feature work: the S3 feature tickets'
viewers, ports and providers are composed at the app root behind `DANAVIEW_FILES_HOME` (default
false, never flipped in code). Integration rights: the slice's share of INT-103 (app root, router,
root pubspec) and of INT-106 (privacy and terms text).

### Files

| File | Change |
|---|---|
| `lib/wiring/documents_wiring.dart` (new, `// OWNER: S3-W`) | The S3 composition: viewer registration per platform, opening the viewer router, the linked-folder document walk, the Share Extension inbox overrides and host, Open with Danaview |
| `lib/wiring/files_home_wiring.dart` (`// EXTENDED: S3-W`) | Documents tab slot (`showDocuments: s3DocumentsShown`); documents and other files open through the viewer router, audio in the player; `openLibraryEntryWith` (any provider reader, for incoming files); `documentsOverrides` added to the S2 overrides; the Home wrapped in `InboxImportHost` |
| `lib/main.dart` (`// EXTENDED: S3-W`) | `installIncomingDocumentOpen(appNavigatorKey, …)` after the S2 overrides; nothing with the flag off |
| `pubspec.yaml` | Path dependencies `danaview_documents` and `danaview_pdf` (the app root builds `PlatformPdfDocuments`; rule 23 keeps `danaview_pdf` out of `danaview_features`). Both plugins were already registered transitively, so no native change |
| `packages/danaview_features/lib/src/more/legal_texts.dart` (`// EXTENDED: S3-W`) | S3 privacy and terms text, only in builds with the flag (below) |
| `test/v12/wiring/s3_wiring_test.dart`, `test/v12/legal/s3_documents_text_test.dart` (new) | Gate tests |
| `test/v12/wiring/s2_wiring_test.dart` (`// EXTENDED: S3-W`) | Two S2 expectations follow S3: the Documents tab is shown, and tapping a document opens the viewer router instead of the file menu |

### What is wired (flag on)

| S3 feature | Where it is reached | Status |
|---|---|---|
| Documents filter and tab (HOM-18) | Home tab strip: Home, All, Videos, Photos, **Documents**, Playlists, Folders. HOM-18's package constant `documentsFilterShown` stays `false` (its own tests pin it); the app passes `showDocuments: s3DocumentsShown` (true) to `libraryFilterTabSlots`, so the switch is the app root's. Rows have the same Rename / Move / Delete menu as All | done |
| Linked-folder documents (HOM-18 §8.1) | `linkedDocumentsProvider` (empty until S3, "the app root overrides it") follows `linkedDocumentScanProvider`: a bounded breadth-first walk of the 1.1 linked roots in a background isolate (2000 folders, 5000 documents, depth 8; hidden entries and iOS "Open in" copies skipped; classified by name, files never opened), re-run when the roots change. Ids are `lk:<root token>/<relative path>` (FNV-1a of the root path), stable across walks. Rows are read-only (HOM-18) | done |
| Viewer router, text/CSV viewer, file card (HOM-23) | Every document or other file the Home opens (All, Documents, Folders, Favourites, Recents, search hits) goes to `openDocumentViewer` → HOM-23's `DocumentViewer` full screen, with the platform's native viewers registered and the file-out port for Open in another app / Share. Recents are recorded by the host (Danaview folder entries only) | done |
| PDF viewer, PDFKit (HOM-24) | `documentViewerSetupFor`: iOS and macOS register `pdfViewerBuilder(PlatformPdfDocuments())` with `pdfViewerProbe` | done |
| PDF viewer, `PdfRenderer` (HOM-25, Windows) | The same registration on Android. Until HOM-25 lands, `capabilities()` answers none and the probe sends PDFs to the file card (pinned by the S3 test) | wired; viewer pending HOM-25 |
| Quick Look and document thumbnails (HOM-26) | iOS and macOS register `quickLookViewerBuilder(NativeQuickLookPort())` with `quickLookProbe` (editing disabled natively). Document thumbnails were already reached through HOM-04's thumbnail service (`ThumbSourceKind.document` → `documentThumbnail`); no S3 wiring needed | done |
| Audio files | Open in the player (router column "player"); in S2 they opened the file menu | done |
| Open with Danaview (HOM-21) | `IncomingMediaBridge.interceptor = incomingDocumentInterceptor(…)`: photos and documents are imported into `Imported` (`sourceHint = openWith`, the source only read; iOS's own `Documents/Inbox` copy removed after) and opened with `openLibraryEntryWith` on the root navigator; videos, streams, `danaview://` links and unknown types return false and keep the 1.1 path (P-7, P-8). A failed import shows "Couldn't open this file." | done |
| Share Extension inbox (HOM-21, INT-104) | iOS only: `inboxPortProvider` = `NativeInboxPort(NativeInbox())`, `inboxChangesProvider` = its `changes`, `inboxStagingDirectoryProvider` = `<support>/DanaviewInboxStaging` (not the cache, which iOS may purge while a staged file waits; excluded from backup). `InboxImportHost` around the Home reads `inboxAutoImportProvider` once: a run on start, on every foreground and on every extension event, folder snapshot refreshed after library writes; a run that saved or failed something shows HOM-21's toast | done |
| Player "Save to Danaview folder" (HOM-21) | The player's Playback sheet (More options) offers "Save to Danaview folder" while a local file plays and the library is open; the More button shows at every width then; flag off or a stream: no row (D-S3W-2) | fixed `cdf3c313` |
| Android incoming intents (HOM-21A, Windows) | Nothing to wire on the Dart side beyond the interceptor; the intents arrive through `IncomingMediaBridge` / `native_incoming.dart` (still a placeholder) | pending HOM-21A |

**Not wired in S3** (later slices, entry points hidden): PDF tools (merge, organise, annotate, sign,
compress: S4; `mergeIntoPdfHandlerProvider` stays null), Edit photo / Batch edit / Make video
montage (INT-105, S8), Search with AI (S7).

### Flag set of the S3 build

- S3-R passes `--dart-define=DANAVIEW_FILES_HOME=true` plus the v1.1 release defines
  (`DANAVIEW_EDITOR`, `DANAVIEW_AUTO_CAPTIONS`); `DANAVIEW_PHOTO_EDITOR`, `DANAVIEW_BEAUTY`,
  `DANAVIEW_AI_STUDIO` stay off. S3 adds no flag: the Documents tab, viewers and share-in ride on
  `DANAVIEW_FILES_HOME`.
- Version stays **`1.0.0+1`** (`--build-name=1.0.0 --build-number=1`); FIX-S1R-1 (fastlane lanes
  pass no dart-defines) still applies, so the manual commands of `S1-QA.md` §Signing are used.
- The S3 candidate embeds the `DanaviewShare` extension (INT-104): signing needs both App IDs with
  the App Group `group.com.vecvel.danaview` (`ios/fastlane/SHARE_EXTENSION.md`).
- With the flag off the **Dart side** is the S1 app (S3 test "flag off", S2 test "flag off",
  INT-101's `flags_off_test.dart`): no documents overrides, no Open-with interceptor, no inbox
  host. The **native side is gated per build** (INT-104 fixer): the source `Info.plist`s keep the
  image, PDF, Office and text `CFBundleDocumentTypes` (rank Alternate), and a "Gate Files Home
  declarations" run-script phase on the Runner target of `ios/Runner.xcodeproj` and of
  `macos/Runner.xcodeproj` decodes `DART_DEFINES` after Info.plist processing. Unless
  `DANAVIEW_FILES_HOME=true` it deletes every rank-Alternate document type from the built
  `Info.plist` (only the 1.1 "Video Media" type is left, so neither the Files app nor Finder offers
  Danaview for photos or documents) and, on iOS, removes the embedded `DanaviewShare.appex` (no
  share-sheet entry, no App Group batches). Each build re-copies the types from the source plist
  first, so an incremental flag flip does not keep stale types; a flag-on iOS build fails if the
  appex is missing. The 1.1 video path is unchanged. The phases were checked by running the script
  against `macos/Runner/Info.plist` with the flag off (Video Media only) and on (all five types);
  the simulator/device check is the gate phase's. Android stays the Windows lane (4173f44). The
  Dart-side guard FIX-S3Q-6 offered is no longer needed for the OS paths.

### Privacy policy, terms and licences

`legal_texts.dart` gets three constant blocks that join the documents through
`if (FeatureFlags.filesHome)`, right after the S2 blocks:

- **What Danaview stores on your device** (`documentsStoredBullets`): *Files shared with Danaview*
  (opened with or shared to Danaview → a copy in Danaview folders, Imported or the picked folder;
  the original never changed); *Share extension (iPhone and iPad)* (the copy first goes to a
  storage area only Danaview and its extension can use, moved into Danaview folders the next time
  the app opens and removed there; an interrupted share removed after 24 hours; the folder names
  kept there for the extension's picker, no file names; not included in backups).
- **Files and permissions** (`documentsPermissionBullets`): *Documents* (open on the device: PDF
  viewer, the in-app text and spreadsheet viewers, the system preview on iPhone, iPad and Mac as
  read-only previews; viewing never changes the file; another app only on Open in another app);
  *Documents in your folders* (the Documents tab lists the linked folders' documents, reading names,
  sizes and dates only; never renamed, moved or deleted); *Opening files with Danaview* (photos and
  documents copied into Imported; videos, streams and links play as before).
- **Terms of Use:** new section "Documents" after "Danaview folders" (read-only, never changed;
  layout may differ from the app that made it; edit with Open in another app).
- **Licences:** no new entry. PDFKit, Quick Look and `PdfRenderer` are system frameworks; S3 bundles
  no third-party native code (PdfBox-Android, HOM-27's choice, arrives with the S4 tools and needs
  its Apache-2.0 entry then).
- No host is named and none is added (ARCH v1.2 §9.1: viewers, Quick Look, thumbnails and the
  Share Extension are offline). `legalEffectiveDate` stays with the owner at S3-R.

### Store-answer deltas (for S3-R and AIS-41)

| Store item | S3 delta |
|---|---|
| App Store App Privacy | Unchanged: "Data Not Collected". Documents are read and shown on the device; the Share Extension copies into the App Group on the device only; nothing leaves the device |
| Privacy manifests | `ios/Runner/PrivacyInfo.xcprivacy` and `ios/DanaviewShare/PrivacyInfo.xcprivacy` (INT-104) declare the file-timestamp and disk-space API reasons; no tracking domains, no collected data types |
| App Store review note | "Danaview appears in the share sheet for photos, videos, PDFs, Office files and text. The extension only copies the shared items into the app's App Group; the app imports them into its own folders on the next launch. Documents open read-only (PDFKit, Quick Look with editing disabled)." |
| App Store: document types | Documents and images are declared at rank **Alternate**, videos keep **Owner** (INT-104), so Danaview never claims to be the default app for documents |
| Export compliance | Unchanged (no encryption added) |
| Google Play Data safety | Unchanged: no data collected or shared |
| Google Play permissions | None added by S3: incoming `VIEW` / `SEND` / `SEND_MULTIPLE` intents need no permission. The filters are on `.IncomingDocumentsAlias` in `android/app/src/main/AndroidManifest.xml` (HOM-21A `8ebb2094`, flag-gated alias `a61160de`; D-S3W-1 fixed) |

### Tests (S3-W)

`test/v12/wiring/s3_wiring_test.dart` (21 tests, green plain and with
`--dart-define=DANAVIEW_FILES_HOME=true`), booting `DanaviewApp` with the real router over an
in-process HOM-17 fixture library (Report.pdf, Notes.docx, Archive.zip, Song.mp3), a stand-in PDF
viewer registered like HOM-24's, and one linked document:

- flag off: `documentsOverrides` is empty on every platform and no interceptor is installed;
- runtime: viewers per platform (PDF + Quick Look on iOS and macOS, PDF on Android, none on Windows
  and Linux); without the plugin the PDF probe sends a PDF to the file card; the Share Extension
  inbox (port, changes, staging under the support folder) only on iOS; library entries become viewer
  files with MIME and UTType, linked ones are never recorded in Recents, `toString` hides the name;
- linked-document walk over a temp folder: documents only (PDF, xlsx, nested txt; not mp4/jpg),
  hidden files and folders and `Documents/Inbox` copies skipped, `lk:` ids parse with the root
  token and relative path and are stable across walks; a missing root yields nothing;
- app: the Documents tab lists Danaview and linked documents (not audio); a PDF opens in the
  registered PDF viewer through `DocumentViewer` and its entry gets `last_opened_at` (Recents); a
  `.zip` gets the file card and Back closes it; audio queues and opens the player; a linked document
  opens in the viewer; the inbox host runs the importer when the Home mounts (port checked, folder
  snapshot written); Open with claims a PDF (imported into the library, opened, source left in
  place) and leaves a stream URL and a `.mov` to the player;
- overflow: Documents tab and the file card at 280, 375, 1280 px × text scale 0.85 and 1.35.

`test/v12/legal/s3_documents_text_test.dart` (5 tests, green plain and with the flag): content of
every block, no host and no "upload", and the blocks are in the policy and the terms exactly when the
build has the flag, in the expected sections.

Also run green: `test/v12/wiring/s2_wiring_test.dart` (plain and with the flag, after its two S3
updates), `test/v12/wiring/s1_wiring_test.dart` (plain), `test/v12/legal`,
`test/editor_entry/legal_texts_test.dart` and `test/privacy_policy_host_test.dart` (plain and with
the flag), `test/architecture/dependency_rules_test.dart`, `test/widget_test.dart`,
`test/incoming_media_test.dart`, `test/editor_routes_test.dart`, `test/editor_wiring_test.dart`,
`test/v12/s2_qa/s2_persistence_test.dart`, `test/v12/preservation/folders`. `flutter analyze
--fatal-infos` on `lib`, `test/v12/wiring`, `test/v12/legal` and `packages/danaview_features/lib/src/more`:
no issues.

Device checks are **deferred: no device available** to S3-Q / S3-R: the PDFKit and Quick Look views
on the simulator, sharing a photo, a PDF and a large video from Photos and Files through the
extension, Open with from Files, the `PdfRenderer` viewer on the emulator (HOM-25), and a
`flutter build ios --no-codesign` with the extension embedded (not run here: the dependency change
adds no plugin, and the 8 GB machine was shared with other builders).

### Fix round after S3-Q (S3-W, 2026-10-23)

S3-W's share of the S3-Q defects, in S3-W's files only:

| Item | Change | Test |
|---|---|---|
| FIX-S3Q-2 | `openDocumentViewer`'s route puts the viewer host in a `Material` (kit background) under `DefaultTextStyle.merge(DanaviewTextStyles.body, no decoration)`, as the photo viewer's scaffold does, so no viewer text falls back to Flutter's debug style | `s3_wiring_test` "the viewer route gives every text the kit style"; S3-Q's matrix with `--dart-define=S3Q_CHECK_TEXT_STYLE=true`: **11 of 11 pass** (was 11 surfaces failing) |
| Open with failure toast | `installIncomingDocumentOpen`'s `onFailed` showed the toast from the navigator's context, which is above its Overlay, so `DanaviewToast` found no overlay and dropped "Couldn't open this file." silently. It now shows it from a context inside one of the overlay's entries (shallow breadth-first search, `Overlay.maybeOf` resolves); the message is the constant `incomingOpenFailedMessage` | `s3_wiring_test` "Open with: a failed import shows …" (a PDF that is gone when the import reads it) |
| FIX-S3Q-1 | `showLibraryEntryFileMenu(context, ref, entry)` opens HOM-22's single-file menu (Share, Open in another app, Save out, Copy to, Move to, Rename, Favourite, File info, Delete). Second round: HOM-18's `LibraryEntryActions` gains `onMore`, a "More actions…" item in the Danaview row menu (All, Documents and Folders tabs pass it; `FoldersTab.onMoreEntry`), and `_rowActions` / the Folders slot pass `showLibraryEntryFileMenu`. `openDocumentViewer(…, fileMenuItem:)` puts a "File actions" button (`viewer-file-menu`) at the end of every viewer's top bar through HOM-23's new `DocumentHostActions` (`viewer_bar.dart`): Share, Open in another app, Save out, Copy to, Favourite, File info (`viewerFileActions`; Move, Rename and Delete stay in the row menu). Favourites and Recents rows reach the same actions through the viewer's button | `s3_wiring_test` "a document entry reaches HOM-22's Share and File info…", "the row menu offers Open and \"More actions…\"…", "the viewer's top bar opens Share, Save out and File info" |
| Flags off | `installIncomingDocumentOpen` with the flag off installs, on iOS and macOS only (where S3's `CFBundleDocumentTypes` ship in every build), a guard that claims photos and documents opened with Danaview (`routeIncoming` = import-and-view) and shows "Danaview can't open this kind of file." instead of handing them to the 1.1 player; nothing is imported or shown. Videos, streams, `danaview://` links and the other platforms keep the 1.1 path. Still open: the Share Extension is embedded in every iOS build, and with the flag off its App Group batches are not imported or cleaned up (S3-Q / owner) | `s3_wiring_test` flag off: no interceptor on Android, Windows, Linux; iOS and macOS claim PDF, docx, txt, jpg and pass mp4, https and `danaview://` |
| Linked-walk test | The walk test pins both columns of HOM-21's `SystemOpenInCopyRoots`: off iOS a `Documents/Inbox` folder in a linked root is the user's own and is listed; on iOS the app's own "Open in" copies are skipped | `s3_wiring_test` linked-document walk |

Run green after the round: `test/v12/wiring/s3_wiring_test.dart`, `test/v12/wiring/s2_wiring_test.dart`,
`test/v12/legal/s3_documents_text_test.dart` (54 plain; 53 + 1 skip with `DANAVIEW_FILES_HOME=true`),
`test/v12/s3_qa/s3_matrix_test.dart` with the text-style check on (11 pass); `flutter analyze
--fatal-infos lib test/v12/wiring test/v12/legal packages/danaview_features/lib/src/more`: no issues.

### Defects and open items

| # | Item | Owner | Status |
|---|---|---|---|
| D-S3W-1 | `android/app/src/main/AndroidManifest.xml` has none of INT-104's Android intent filters (`application/pdf`, Office MIME types, `text/*`, `image/*` on `VIEW` / `SEND` / `SEND_MULTIPLE`), so on Android no document or image can be opened with or shared to Danaview; HOM-21A needs them | INT-104 (Android part, Windows lane) | fixed: HOM-21A `8ebb2094`, flag-gated alias `a61160de` (aapt2-verified, §7 Release candidate) |
| D-S3W-2 | HOM-21's "Save to Danaview folder" (`canSaveToDanaviewFolder`, `saveToDanaviewFolder` in `danaview_player_actions.dart`) is not offered by any player menu (`danaview_player_screen.dart` / the controls overlay do not call it) | HOM-21 | fixed `cdf3c313`: a "Save to Danaview folder" row in the Playback sheet; `test/v12/incoming/player_save_menu_test.dart` |
| D-S3W-3 | `test/v12/s2_qa/s2_matrix_test.dart` (S2-Q) walks "document file menu → File info" by tapping a document row; from S3 that opens the viewer router (10 matrix tests fail at `tapKey('file-info')`). The step should open File info from the file card or the row menu, or move to S3-Q's matrix | S2-Q / S3-Q | fixed `c8853faf` (reaches File info through "More actions…"; 10 pass, re-run in S4 fixes) |
| D-S3W-4 | HOM-18's `documentsFilterShown` stays `false` and its tests pin it; the app shows Documents through `s3DocumentsShown`. HOM-18 may flip its constant (and `filters_test.dart`) so the package default matches the shipped app | HOM-18 | open, low |
| D-S3W-5 | FIX-S3Q-1's row hook (`LibraryEntryActions.onMore`, "More actions…") is in HOM-18's `entry_widgets.dart`, `all_tab.dart`, `documents_tab.dart`, `folders_tab.dart` (S3-W fix round 2, for FIX-S3Q-1) | HOM-18 | fixed |
| D-6 (S2) | The features barrel still exports none of the Files & Media Home surfaces; both wiring files use `implementation_imports` | INT-101 (barrel) | open, low |
| — | `legalEffectiveDate`, the owner's review of the S3 wording, regenerating the hosted privacy page from a build with the flag, App Group on both App IDs before signing | S3-R with the owner | open |

## Slice QA

Ticket **S3-Q**, Mac half, on `v1.2-wip`, 2026-10-23, 12:10–14:05. Tree: `c326ea60` and the
backup commits after it up to `8bff0378`, which add only S3-W's and S3-Q's files and the refreshed
`ios/Podfile.lock` (N-S3-2); product code identical to `c326ea60`. QA changed no product code; every
defect below is a FIX ticket. The Android Emulator half runs on the Windows laptop (**pending:
Windows**).

**Gate verdict (Mac half): red.** The S3 packages, the native XCTests, the architecture test,
HOM-15, the composed overflow / accessibility matrix, the S3 E2E on the iOS 26.5 iPhone 16 and the
v1.1 iOS suite with `DANAVIEW_FILES_HOME=true` (20 of 20) are green, and the real Share Extension (Files and Photos) and Open with Danaview from Files work on the
simulator. Two blocking defects were found on the simulator: every document viewer draws its text
with Flutter's fallback style (yellow double underline, FIX-S3Q-2), and a Danaview-folder document
can no longer be shared, saved out, favourited, copied or shown in File info, because S3 routes the
row tap to the viewer and nothing else offers HOM-22's file menu (FIX-S3Q-1). Open low items:
FIX-S3Q-3…6 and the S3-W open items (D-S3W-1, D-S3W-2).

### 1. S3 packages and suites

| Package / suite | Command | Analyze | Tests |
|---|---|---|---|
| `danaview_documents` (HOM-23, HOM-24 viewer, HOM-26 Dart) | `flutter analyze --fatal-infos && flutter test -j 1` | clean | **216 pass** (incl. HOM-23's 50 MB log: 52.5 MB, 662 842 rows, load 186 ms, median frame 1.6 ms, p90 3.2 ms, max 5.3 ms) |
| `danaview_pdf` (HOM-24 surface) | same | clean | 5 pass |
| `danaview_library_native` (Dart side incl. Quick Look and Inbox wrappers) | same | clean | 22 pass |
| `danaview_library` inbox (HOM-21: importer, folder snapshot, Open with) | `dart analyze --fatal-infos`; `dart test -j 1 test/inbox` | clean | 19 pass |
| `danaview_features` | `flutter analyze --fatal-infos` | clean | (tests in root `test/v12`) |
| XCTests, macOS runners | `darwin/Tests/QuickLook/run_xctests.sh macos`, `…/Inbox/run_xctests.sh macos`, `danaview_pdf/darwin/Tests/Viewer/run_xctests.sh macos` | — | Quick Look 20 (core 13, glue 7), Inbox 9, PDF viewer 18 (core 11, glue 7): **all pass** |
| iOS type-check of the plugin sources | `QuickLook/run_xctests.sh ios-typecheck`, `Viewer/run_xctests.sh ios-typecheck` | passed | — |
| Root: `test/architecture`, `test/v12/{wiring,legal,incoming,filters,s2_qa}`, flags off | `flutter test -j 1 …` | — | 219 pass, 2 skip, **10 fail: all `s2_qa/s2_matrix_test.dart`** (D-S3W-3 → FIX-S3Q-3) |
| Same with `DANAVIEW_FILES_HOME=true` | `flutter test -j 1 --dart-define=DANAVIEW_FILES_HOME=true …` | — | 215 pass, 3 skip, 13 fail: the same 10 plus the 3 flag-off assertions of `s1_wiring_test.dart` (N-2 of S2; `int101/flags_off_test.dart` adds its known 6 when run) |
| S3-Q's matrix (`test/v12/s3_qa/s3_matrix_test.dart`, §5) | `flutter test -j 1` | clean | **10 pass, 1 skip** (the FIX-S3Q-2 check, which fails on 11 surfaces when enabled) |
| HOM-15 preservation suite | `scripts/ci/v12/home_preservation.sh -j 1`; again with `--dart-define=DANAVIEW_FILES_HOME=true` | — | **406 pass; 406 pass** |
| Analyze of S3-Q's files | `flutter analyze --fatal-infos integration_test/v12/s3 test/v12/s3_qa` | clean | — |

The other `test/v12` directories were not re-run (owner preference: short runs; S3 changed none of
their code). The S3-W wiring and legal tests are inside the root rows above and pass with and
without the flag.

### 2. S3 E2E on the iOS Simulator (iPhone 16, iOS 26.5)

`integration_test/v12/s3/s3_documents_test.dart` (new, `// OWNER: S3-Q`) with documents generated by
`integration_test/v12/s3/tool/make_s3_docs.sh` into `build/e2e/s3_docs/` (the committed
`spikes/android_pdf/fixtures` PDFs, a 3 000-line UTF-8 text with accents, CJK and emoji, a 400-row
CSV with quoted commas and newlines, a minimal Word file and a zip built by Python's `zipfile`,
a Pillow JPEG; nothing downloaded):

```text
integration_test/v12/s3/tool/make_s3_docs.sh
DV_E2E_IPHONE="iPhone 16" DV_E2E_IPHONE_RUNTIME="iOS 26.5" \
DV_E2E_EXTRA_DEFINES="DANAVIEW_FILES_HOME=true DV_S3_DOCS=$PWD/build/e2e/s3_docs" \
  scripts/ci/editor/e2e_ios.sh --target integration_test/v12/s3/s3_documents_test.dart iphone
```

It boots the app as `lib/main.dart` does: `filesHomeOverrides` (with S3-W's `documentsOverrides`:
real PDFKit through `PlatformPdfDocuments`, the real Quick Look probe, the App Group inbox) and
`installIncomingDocumentOpen` on the app navigator. System UI a Flutter test can't drive is replaced
at the app's own seams, as in S2: the Files picker stages copies into the app's staging folder, the
file-out port records Share / Open in, and Quick Look's `present` is recorded (its `canPreview` is the
native one). Four earlier attempts failed on the test's own assumptions (a zip is a "document" of
kind other, lazily built rows, a `pump` while the lifecycle was `paused` hangs the live binding) and
were fixed in the test; **the final run passes, 1 of 1, 12:54–12:57**:

| Step | Result |
|---|---|
| Home with the flag: tabs Home, All, Videos, Photos, **Documents**, Folders; Open with interceptor installed | pass (`s3-01-home`) |
| Import "From Files" into Imported: PDF (200 pages), text, CSV, Word, zip; copies byte-equal; staged copies removed; all five classified `document` | pass |
| Documents tab lists them; PDF sub-filter shows the PDF only | pass (`s3-03`) |
| Documents row menu | **Open, Rename…, Move to…, Delete only**: no Share, Save to Files, File info, Favourite, Copy to, Open in another app (FIX-S3Q-1, `s3-04`) |
| PDF in PDFKit: "Page 1 of 200" 1 704 ms after the tap (document info 1 541 ms); search for a page token "1 of 1 match"; page thumbnails; "Open in another app" hands over the library file (`application/pdf`) | pass (`s3-05`…`s3-07`). Debug build on the simulator: the ≤ 500 ms first page is HOM-24's mid-tier device budget, deferred: no device available |
| Text, CSV, Word: the router asks Quick Look first (ARCH §3, Apple column); real `canPreview` true for all three; preview presented, viewer closes on dismissal | pass (`s3-08-*`) |
| Quick Look failing → the in-app text viewer (UTF-8, CJK lines shown) and the CSV grid (cells shown) | pass (`s3-09`, `s3-10`), but the text is drawn with the fallback style (FIX-S3Q-2) |
| zip → file card; Share and Open in another app hand over the library file | pass (`s3-11`) |
| Recents record every open | pass |
| Open with Danaview: a PDF in `Documents/Inbox` delivered on `danaview/media_intent` (`onOpenMedia`, as the AppDelegate does) → imported into Imported, `sourceHint openWith`, PDF viewer shown, system copy removed; the same file as a `file://` URI from outside the app opens the existing entry (no second copy), source unchanged | pass (`s3-12`) |
| Share Extension inbox: a batch written as `InboxWriter.swift` does (PDF + JPEG, target folder chosen) in the real App Group container, next to an interrupted batch (no manifest); on foreground both items land in the folder (`sourceHint shareExtension`), toast "2 shared items saved", batch deleted, interrupted batch left and not imported; the folder snapshot for the extension's picker lists the new folder | pass (`s3-13`) |
| Library closed and reopened: all entries, the shared items and Recents persist; the PDF opens again | pass (`s3-14`) |
| Originals (8 files): bytes and timestamps unchanged | pass |
| Network: no `HttpClient` created | pass |

**Real system UI on the simulator** (manual drive with the simulator tool on a debug build of
`lib/main.dart` with `DANAVIEW_FILES_HOME=true DANAVIEW_EDITOR=true DANAVIEW_AUTO_CAPTIONS=true`,
documents copied into Files' "On My iPhone › S3QA", the JPEG added to Photos with `simctl addmedia`;
the app and the folder were removed afterwards, the generated photo stays in the simulator's
Photos):

| Check | Result |
|---|---|
| Files › long press `s3_shared.pdf` › Share › **Danaview** | the extension's sheet "Save to Danaview · 1 item · choose a folder" (folder list from the snapshot: Imported) › Save; the batch was imported at once by the running app (Darwin notification): entry `s3_shared.pdf`, `shareExtension`, SHA-1 equal to the source; `Inbox/` empty afterwards |
| Photos › the JPEG › Share › **Danaview** › Save | entry `s3_shared.JPG`, `shareExtension`, 24 558 B (= source) |
| Files › long press `s3_notes.txt` › Open With › **Danaview** | the app opened (in place, `LSSupportsOpeningDocumentsInPlace`), imported the file (`openWith`) and showed it in the **real QLPreviewController**: no Markup control, Share only; × closed it (`m02`) |
| PDF from the Documents tab | PDFKit view with the annotations (highlight, strike-out, note); title and "Page 1 of 2" drawn with the yellow double underline (`m01`, FIX-S3Q-2) |
| Kill and relaunch | Documents tab still lists both documents, with the PDF's first-page thumbnail (`m03`) |
| Backup exclusion | `com_apple_backup_excludeItem` set on the App Group `Inbox/` and on `Application Support/DanaviewInboxStaging` |
| Sources in Files | SHA-1 and mtime (`20 Oct 2026 09:00`) unchanged |

Not done here: a 2 GB video through the extension and its Instruments memory record (HOM-21 device
check; deferred: no device available), "Save to Danaview folder" from the player (not wired,
D-S3W-2), password PDFs on the simulator (HOM-24's XCTests cover them). Evidence (not committed):
`build/e2e/ios/6663101E-6BE7-47D4-B3B8-055700BF2E02/s3q_evidence/` (16 E2E screenshots, the passing
log, 3 manual screenshots).

### 3. v1.1 iOS suite with `DANAVIEW_FILES_HOME=true`

`DV_E2E_IPHONE="iPhone 16" DV_E2E_IPHONE_RUNTIME="iOS 26.5" DV_E2E_MODELS=/Users/besaoct/danaview-models
DV_E2E_EXTRA_DEFINES="DANAVIEW_FILES_HOME=true" scripts/ci/editor/e2e_ios.sh iphone` (plus
`DV_E2E_SKIP_PODS=1 DV_E2E_SKIP_WHISPER=1`: pods had just been installed and WhisperCore is current),
13:06–13:57, one batch, models read in place from `/Users/besaoct/danaview-models` (nothing
downloaded). The define reaches `flutter test` through `e2e_host.sh -D`, the same path that carried
it to the S3 E2E, which refuses to start without it. `E2eApp._boot` adds `filesHomeOverrides`, so the
suite runs on the wired library **with S3-W's `documentsOverrides`** (viewers, linked-document scan,
App Group inbox and its host); it does not install the Open-with interceptor (FIX-S3Q-5, low).

| Batch | Result |
|---|---|
| S3 flag set (`DANAVIEW_FILES_HOME=true`, plus the script's `DANAVIEW_EDITOR`, `DANAVIEW_AUTO_CAPTIONS`) | **20 of 20 files pass** (s01–s18, `x_android_api28`, `x_ios_background_export`; `x_android_export_background` skipped on iOS as designed). s05 hit the known harness hiccup once ("No tests ran." after the build, the 900 s watchdog) and passed on the script's automatic re-run |
| Flags off | not re-run: S3 changes nothing outside the flag (S3-W's flag-off tests, §1), so S2-Q's flag-off batch stands |

Simulator realities, reported not failed: HEVC/MOV not offered (`hevcEncode false`);
`pausedInBackground observed: false`; s13 start latency 500 ms (device budget 100 ms), voiceover
-40.9 dBFS; s07 burned cues 341 / 324 changed samples; s08 3 cues; s15 head -14.6 dBFS, body
-9.0 dBFS. The simulator was booted for the S3 E2E (12:21) and kept for the manual checks and this
batch; S3-Q shut it down at 13:58. The iPad Pro 13 was not touched. Logs and summary:
`build/e2e/ios/6663101E-6BE7-47D4-B3B8-055700BF2E02/` (`summary.txt`, `logs/`).

### 4. Persistence (QA-106 scope for S3)

S3 stores: the entries the inbox and Open with create (HOM-17's store, covered by S2's persistence
tests), Recents of document opens, the App Group `Inbox/` and `folder-snapshot.json`, and the
staging folder. Shown: entries, Recents and shared items survive a store close/reopen (E2E §2) and a
kill/relaunch (manual §2); `Inbox/` and `DanaviewInboxStaging` are excluded from backup; an
interrupted batch is never imported; the 24 h stale deletion is covered by HOM-21's Inbox XCTests
(9 pass) and `danaview_library/test/inbox`. iOS device backup / restore: deferred: no device
available.

### 5. Overflow and accessibility (QA-105 scope for S3)

`test/v12/s3_qa/s3_matrix_test.dart` (new, `// OWNER: S3-Q`) boots `DanaviewApp` with the app router,
the S2 + S3 wiring over a HOM-17 fixture library with very long names, the iOS column of the router
(`debugDefaultTargetPlatformOverride`), a stand-in PDFKit store and view (120 pages, outline,
search hits), a Quick Look port that previews Word only and a linked-folder PDF, and visits: the
Documents tab (Danaview and linked rows), the Word sub-filter, an empty sub-filter, a row menu, the
PDF viewer with its search, pages and contents panels and options menu, the Quick Look screen while
the preview shows, the text viewer and its options, the CSV grid, the file card, a linked PDF, and
the inbox and Open-with toasts.

| Check | Sizes | Result |
|---|---|---|
| No exception (overflow) on every surface | 280, 375, 768, 1280 px × text scale 0.85, 1.35 | pass (8 runs) |
| `iOSTapTargetGuideline`, `labeledTapTargetGuideline`, `textContrastGuideline` on every surface | 375 px × 1.0, 1280 px × 1.35 | pass (2 runs) |
| No text drawn with the fallback style (yellow double underline) | 375 px × 1.0 | **fails on 11 surfaces** (every viewer, the file card) when enabled with `--dart-define=S3Q_CHECK_TEXT_STYLE=true`; skipped by default until FIX-S3Q-2 lands |

The guideline checks pass although the text is underlined: contrast and targets don't see text
decoration, which is why the extra check was added. VoiceOver on the viewers: deferred: no device
available (simulator VoiceOver not scripted).

### 6. Network guard (QA-103 scope for S3)

- S3 adds **no host**. Static scan of `danaview_documents/lib`, `danaview_pdf/lib` and
  `darwin/Classes`, `danaview_library_native/darwin/Classes/{QuickLook,Inbox}`,
  `danaview_library/lib/src/inbox`, `ios/DanaviewShare`, `lib/wiring/documents_wiring.dart` for
  `HttpClient`, `package:http`, sockets, `URLSession`, `NSURLConnection`, `Uri.http(s)` and URLs: only
  the plist DTD URLs.
- Rule 30 scan of the same paths for `print`, `debugPrint`, `NSLog`, `os_log`: none.
- HttpOverrides spies: no `HttpClient` in the S3 E2E (§2) or the matrix flows (§5).

### 7. Android Emulator half

Windows / Android lane, branch `v1.2-android`, 2026-10-23, 16:08–17:50. **Trees:** the S3 E2E and
the v1.1 suite ran on `88c0c1c9` (= `b69264a9`, which carries `origin/v1.2-wip` up to the Mac's S3
gate `ff101df3` with HOM-25 and HOM-21A incl. the flag-gated alias, plus the new Android E2E); at the
lead's request `origin/v1.2-wip` (`e9e6eeba`, with the full-width card-grid UI `14dc89fe`) and
`origin/hom21a-android` (`8e02dd93`, 0dc39697's shared-text naming and the alias-aware JVM manifest
test) were then merged (`66595c4f`), and the S3 E2E, the tablet grid check and S3-R ran on that tree.
Version `1.0.0+1` untouched. Host: Windows 11, Flutter 3.44.8, JBR 21.0.10. Emulators:
**Pixel_9_Pro_XL_API_35** on `emulator-5554` (cold boot, `-no-snapshot-load`) and
**Pixel_Tablet_API_35** on `emulator-5558` (`-gpu host`, cold boot). QA changed no product code.
Evidence (not committed): `build/s3_android/` and `build/e2e/android/` in `C:/dev/v12`.

**Gate verdict (Android half): green, with two low FIX requests (FIX-S3Q-A1 MIME of Office files,
FIX-S3Q-A2 PdfBox-Android licence entry).** The S3 E2E Android variant passes 1 of 1 on both trees,
the full v1.1 suite with the S3 flag set passes (s13 is the owner-accepted emulator-microphone
limitation; s02 failed once on a player seek and passed on its re-run), the flag-off build offers
Danaview for no document, photo or text intent while videos keep the 1.1 path, and the tablet grids
match 14dc89fe. **D-S3W-1 is fixed** by HOM-21A (`8ebb2094`, alias `a61160de`, merged into v1.2-wip
in `ff101df3`): the VIEW / SEND / SEND_MULTIPLE filters for PDF, Office, OpenDocument, RTF, `text/*`
and `image/*` (+ `video/*` on SEND) are on `.IncomingDocumentsAlias`, enabled only in a
`DANAVIEW_FILES_HOME=true` build (§Release candidate, Android candidate).

#### 7.1 S3 E2E on the Android Emulator (`ACTION_VIEW` / `ACTION_SEND` instead of the App Group inbox)

`integration_test/v12/s3/s3_documents_android_test.dart` (new, `// OWNER: S3-Q (Android half)`,
`88c0c1c9`) mirrors the iOS scenario on the real S2 + S3 wiring (`filesHomeOverrides` with
`documentsOverrides`: HOM-25's `PdfRenderer` viewer and HOM-21A's `NativeIncomingPort`;
`installIncomingDocumentOpen` as `lib/main.dart`). Open with and Share to Danaview are **real
intents**: the host driver sends them with `am start` to `.IncomingDocumentsAlias` through a new
handshake action `sendIntent` (`e2e_host.sh`, EXTENDED: S3-Q; only VIEW / SEND, only the app's own
FileProvider URIs under `<cacheDir>/danaview-out/`, only the app's two components). `am` has no
Uri-list extra, so ACTION_SEND_MULTIPLE is covered by the real Files share in the release smoke
(§Release candidate) and HOM-21A's instrumented `IncomingAppE2eTest`. `e2e_android.sh` stages the
documents like the S2 media (`DV_S3_DOCS_HOST`, default `build/e2e/s3_docs`):

```text
integration_test/v12/s3/tool/make_s3_docs.sh                 # Pillow + the committed spike fixtures
DANAVIEW_E2E_FRESH=1 DV_E2E_EXTRA_DEFINES="DANAVIEW_FILES_HOME=true" \
  scripts/ci/editor/e2e_android.sh --target integration_test/v12/s3/s3_documents_android_test.dart emulator-5554
```

Five earlier attempts failed on the harness or the test, none on the app: stale handshake files of an
older install (fixed in `e2e_android.sh`'s fresh start, `23e1013e`), `am`'s missing Uri-list extra
(SEND_MULTIPLE replaced by two SENDs), the list reveal holding a Scrollable that the tab rebuilt while
scrolling on a used install ("No element", the same step the Mac saw flake; the reveal now looks the
list up before every drag), and a used install whose library already held the Open-with PDF (VIEW
dedupes by content, as designed; the scenario now asserts a fresh install). **The final run passes,
1 of 1** (16:28–16:31, `88c0c1c9`), and again on the merged tree (17:27, `66595c4f`):

| Step | Result |
|---|---|
| Home with the flag: Home, All, Videos, Photos, **Documents**, Folders; Open with interceptor and the incoming-intent importer installed | pass (`s3a-01`) |
| Import "From Files" into Imported: PDF (200 pages), text, CSV, Word, zip; copies byte-equal; staged copies removed; all five `document` | pass |
| Documents tab, PDF sub-filter | pass (`s3a-03`) |
| Row menu Open, Rename…, Move to…, **More actions…**, Delete → HOM-22's menu (Share, Open in another app, Save out, Copy to, Move to, Rename, Favourite, File info, Delete) → File info | pass (`s3a-04`, `-04b`, `-04c`; FIX-S3Q-1 holds on Android) |
| PDF in `PdfRenderer`: "Page 1 of 200" 1 795 ms after the tap (merged tree 2 000 ms; debug build on the emulator, the ≤ 500 ms budget is the mid-tier device's); search for page 150's token "1 of 1 match" in 2.4 s (API 35 platform text, no pre-warm); page thumbnails; Open in another app and the top bar's Share hand over the library file | pass (`s3a-05`…`-07b`) |
| Text in the in-app viewer (UTF-8, CJK), CSV in the grid (cells, `Zürich`), rows right under the header in Figtree (FIX-S3Q-8 holds) | pass (`s3a-08`, `-09`) |
| Word → file card (Android Office, V2-121), Open in another app hands it over **as `application/msword`** (FIX-S3Q-A1); zip → file card, Share and Open in hand over the library file | pass (`s3a-10`, `-11`) |
| Recents record every open | pass |
| **Open with**: `ACTION_VIEW application/pdf` (content URI) → imported into Imported, `sourceHint openWith`, PDF viewer shown; the same file again opens the existing entry, no second copy | pass (`s3a-12`) |
| **Share to**: `ACTION_SEND` of a PDF, then of a JPEG → each into Imported, `sourceHint shareExtension`, toast "1 shared item saved", JPEG `photo`; `ACTION_SEND text/plain` with a subject → `s3q_shared_note.txt` holding the text | pass (`s3a-13`) |
| Library closed and reopened: entries, shared items, Recents persist; the PDF opens again | pass (`s3a-14`) |
| Originals (8 files): bytes and timestamps unchanged; no `HttpClient` | pass |

Evidence: `build/s3_android/e2e_s3/` and `build/s3_android/e2e_s3_merged/` (log and screenshots),
run logs `build/s3_android/e2e_s3_run*.log`.

#### 7.2 Full v1.1 suite on the Android Emulator with the S3 flag set

`DANAVIEW_E2E_MODELS=C:/dev/models DANAVIEW_E2E_FRESH=1 DV_E2E_EXTRA_DEFINES="DANAVIEW_FILES_HOME=true"
scripts/ci/editor/e2e_android.sh emulator-5554` (API 35, headless; FIX-S2Q-A2's pass-through, so no
`flutter` wrapper this time), 16:31–17:23 on `88c0c1c9`, plus the script's `DANAVIEW_EDITOR=true
DANAVIEW_AUTO_CAPTIONS=true`. `E2eApp._boot` adds `filesHomeOverrides` with S3-W's
`documentsOverrides`; the library under `files/library` existed after the batches, so the flag
reached the app.

| Batch | Result |
|---|---|
| s01, s03–s12, s14–s18 | **16 pass**, no harness retry, no emulator restart |
| s02 | failed once ("player position to reach 0:05:10 after a second seek", 00:00 / 00:08 under software rendering), **passed on its re-run** (`--target s02`, 17:23–17:25): emulator playback flake, as OBS-S2A-2 |
| s13 | fail: voiceover level -79.1 dBFS (needs > -60), emulator microphone silence (owner-accepted); start latency 500 ms |
| `x_android_export_background` fgs, cancel, swipe, death | **4 of 4 pass** |

s07 burned cues 313 / 293 changed samples, HEVC/MOV not offered (reported); s08 3 cues; s15 head
-15.1 dBFS, body -9.0 dBFS. Summary: `build/s3_android/v11_suite_summary.txt`, logs
`build/e2e/android/emulator-5554/logs/`. Flags-off batch not repeated (S3 changes nothing outside
the flag on the Dart side; the native side is §Release candidate's flag-off check).

#### 7.3 Tablet grids (Mac 0dc39697, UI change 14dc89fe)

Release APK of §Release candidate (`66595c4f`, `DANAVIEW_FILES_HOME=true`) on Pixel_Tablet_API_35
(2560 × 1600 px, 320 dpi = 1 280 × 800 dp in landscape), five documents and a photo imported through
the real DocumentsUI picker. Screenshots
`build/e2e/android/manual/s3_grids_{home,all,documents}_{landscape,portrait}.png`.

| Check | Landscape | Portrait |
|---|---|---|
| Home: search field full width with **Import** beside it; Open file / folder / link cards across the width | pass | pass |
| All and Documents: wrapping cards, equal heights | 4 columns, 294 dp each | 2 columns, 370 dp each |
| Minimum column about 264 dp (4 × 264 + gaps fits 1 216 dp; 3 × 264 + gaps does not fit 752 dp) | pass | pass |
| Gaps 12 dp (24 px between cards); page margin 32 dp / 24 dp | pass | pass |
| No max-width cap (cards and search reach the page margins) | pass | pass |

On the phone (Pixel 9 Pro XL) the same build shows the search field with a round **+** Import
button beside it (release smoke `r03`).

#### 7.4 Notes from the Android half

- N-S3A-1: `8e02dd93` is in the candidate: a text shared without a subject became
  `Shared text 2026-10-23 1745.txt` (release smoke), with a subject the subject's name (E2E).
- N-S3A-2: Android shares land in Imported (no folder picker on Android); checklist item 9's
  "chosen folder" is iOS only.
- N-S3A-3: the PDF viewer's top bar shows two identical "…" buttons (File actions, View options) on
  Android as on iOS; say if one should get a different icon.

#### 7.5 FIX requests from the Android half

| Id | Owner | Defect | Evidence | Fix direction |
|---|---|---|---|---|
| FIX-S3Q-A1 (low) | S3-W (`documents_wiring.dart` `documentTypeOf`) with HOM-23 | `documentTypeOf` returns the first MIME and UTI of the classifier row, so every Word-row file (`.docx`, `.odt`, `.rtf`, `.pages`) is handed to Open in another app / Share as `application/msword` / `com.microsoft.word.doc`, and the Excel and PowerPoint rows likewise; an app that keys on the exact type may refuse or mis-open the file | §7.1 "Word → file card … as `application/msword`"; `type_table.dart` Word row | Pick the MIME / UTI that matches the file's extension, and test `.docx` → `application/vnd.openxmlformats-officedocument.wordprocessingml.document` |
| FIX-S3Q-A2 (low, licence) | S3-W / INT-106 (`legal_texts.dart` Licences) with the owner | PdfBox-Android 2.0.27.0 (Apache-2.0; `danaview_pdf`'s Android dependency for HOM-25's text and search below API 35) ships in the S3 Android build (its `com/tom_roush/pdfbox` resources alone are 4.4 MB of the AAB), but §Wiring says S3 bundles no third-party native code and adds no licence entry until S4 | `unzip -l app-release.aab`; `packages/danaview_pdf/android/build.gradle.kts` | Add the PdfBox-Android Apache-2.0 entry (with its NOTICE) to the Licences now, in builds with `DANAVIEW_FILES_HOME` |

### 8. Defects (FIX tickets, block the gate unless marked low)

| Id | Owner | Defect | Evidence | Fix direction |
|---|---|---|---|---|
| **FIX-S3Q-1** | S3-W (`lib/wiring/files_home_wiring.dart` `_rowActions` / the Documents slot) with HOM-18 (`LibraryEntryActions`, `entry_widgets.dart`) | With the flag on, a Danaview-folder document (and any "other" file) has no way to Share, Save to Files, Copy to…, Favourite, show File info or (except PDF and the file card) Open in another app: in S2 its tap opened HOM-22's file menu, from S3 the tap opens the viewer, the row menu has Open / Rename / Move / Delete only, the PDF viewer offers only "Open in another app" and the Documents tab has no selection bar. HOM-22's acceptance ("every action…") and S2's "file actions and saving out" regress for documents | E2E §2 row "Documents row menu" (`s3-04`); D-S3W-3 is the same change seen from the S2 matrix | Give the document rows (All, Documents, Folders, Favourites, Recents) HOM-22's single-file menu in the "More" menu (`runFileAction` with Share, Save out, Copy to, Favourite, File info, Open in another app), or long-press selection with the file group; then S3-Q re-runs §2 |
| **FIX-S3Q-2** | HOM-23 (`danaview_documents/lib/src/router/document_viewer.dart`, the host) or S3-W (`openDocumentViewer`'s route) | Every document viewer (PDF chrome, Quick Look screen, text viewer, CSV grid, file card, linked PDF) draws its text with Flutter's fallback `DefaultTextStyle`: yellow double underlines and the wrong weight. The route is a bare `PageRouteBuilder` and the host adds no kit text style (the photo viewer's screen does) | Simulator screenshots `s3-09-text-viewer`, `m01`; S3-Q matrix check (11 surfaces) | Wrap the host (or the route) in the kit's screen/`DefaultTextStyle` (`DanaviewTextStyles.body`, no decoration); unskip `S3 surfaces: every text uses the kit text style` |
| FIX-S3Q-3 (low, test only) | S2-Q (`test/v12/s2_qa/s2_matrix_test.dart`), = D-S3W-3 | The S2 matrix taps a document row to reach "file menu → File info"; from S3 that opens the viewer, so 10 matrix tests fail at `tapKey('file-info')` with or without the flag | §1 root rows | Reach File info through the fixed FIX-S3Q-1 menu (or drop the step: S3-Q's matrix covers the viewers). **Fixed** `c8853faf`: the matrix opens File info through "More actions…"; `s2_matrix_test.dart` 10 pass |
| FIX-S3Q-4 (low) | HOM-20 / HOM-21 (import facts) with HOM-18 | Imported PDFs get no `entry_meta.pageCount`, so Documents rows show "size · date" without the page count HOM-18 specifies | Manual §2 (`s3_shared.pdf` row "6.4 KB · 23 Oct 2026"); matrix fixtures set it by hand | Read the page count after the copy (PDFKit / `PdfRenderer` probe through the import hook, as FIX-S2Q-3 did for photo facts). **Fixed** `cc2d6e12`: `ImportService(countPages:)` probes the copy through `danaview_pdf` (native background thread) and writes `pageCount` in the commit; `backfillPageCounts` fills in older PDFs (at most 200 per run) when the import service starts; real iOS / macOS / Android hosts only. Tests: `packages/danaview_library/test/import/document_facts_test.dart`, `s3_wiring_test` |
| FIX-S3Q-5 (low, QA tooling) | QA-00 (`integration_test/editor/support/e2e_app.dart`) | `E2eApp._boot` adds `filesHomeOverrides` but not S3-W's `installIncomingDocumentOpen`, so the flag-on v1.1 suite runs without the Open with interceptor `lib/main.dart` installs (videos keep the 1.1 path either way, so no v1.1 scenario changes) | §3 | Call `installIncomingDocumentOpen(appNavigatorKey, …)` in the boot as `main.dart` does. **Fixed** `6f2684ac` |
| D-S3W-2 (fixed `cdf3c313`) | HOM-21 | Player "Save to Danaview folder" is not offered by any player menu | §Wiring | as there |
| D-S3W-1 (fixed: HOM-21A `8ebb2094`, alias `a61160de`) | INT-104 Android | No Android document/image intent filters | §Wiring | Windows lane |

Notes (not defects):

- N-S3-1: on iOS the router sends text and CSV to Quick Look first (ARCH §3, Apple column); the
  in-app text viewer and CSV grid show only when Quick Look can't preview or fails (proven in §2).
  If the owner wants the in-app viewers (encoding menu, virtualised 50 MB logs) for text on iOS,
  that is a router change for HOM-23.
- N-S3-2: the committed `ios/Podfile.lock` carried a stale `danaview_pdf` checksum;
  `e2e_ios.sh`'s `pod install` refreshed it (`1e9ee66…` → `40d76ea…`) and a backup commit took it.
  Nothing else changed.
- N-S3-3: the Documents row of the text file shows the type icon, not a Quick Look thumbnail (PDFs
  get their first page); HOM-18 allows either.
- N-S3-4: the share sheet lists one "Danaview" target (the extension); "Open With › Danaview" in
  Files' menu is the Open-with path. Both work.

### Files added by S3-Q

| File | Purpose |
|---|---|
| `integration_test/v12/s3/s3_documents_test.dart` | S3 E2E scenario (§2) |
| `integration_test/v12/s3/tool/make_s3_docs.sh` | Local test documents (fixtures, Python, Pillow) |
| `test/v12/s3_qa/s3_matrix_test.dart` | Composed overflow / a11y / text-style matrix and HttpOverrides guard (§5, §6) |
| `docs/v1.2/qa/S3-QA.md` | This section |
| `test/v12/s3_qa/s3_flag_off_incoming_test.dart` | Flag-off Open with guard on iOS and macOS (FIX-S3Q-6), runs by default since the re-check |
| `test/v12/s3_qa/s3_documents_scroll_test.dart` | Documents tab with 5,000 generated documents (S3's share of HOM-14 / HOM-32) |

## Re-check (2026-10-23)

S3-Q targeted re-check, Mac half, 15:00–15:25, on `v1.2-wip` after the HOM-21, HOM-23, HOM-24 and
S3-W fix rounds (tree `2ae2b294`). Not a full re-run: analyze, the tests of the fixed files, the
architecture test, HOM-15 (a fixer touched `danaview_player_actions.dart`, outside the document
paths), the S3 E2E once on the iOS 26.5 iPhone 16 (shut down afterwards) and the screenshots. QA
changed only S3-Q's files.

### Results

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos lib integration_test`; `danaview_documents`, `danaview_pdf`, `danaview_library_native`, `danaview_features`; `dart analyze --fatal-infos` `danaview_library` | clean |
| `danaview_documents`: `test/pdf/viewer`, `test/text`, `test/card` | 106 pass |
| PDF XCTests (`danaview_pdf/darwin/Tests/Viewer/run_xctests.sh macos`, Swift changed: main-thread replies) | core 11, glue 8: **19 pass** |
| `test/architecture` | 93 pass, 2 skip |
| `test/v12/wiring/s3_wiring_test.dart` / `s2_wiring_test.dart` / `filters/filters_test.dart` / `incoming/player_incoming_actions_test.dart` | 24 / 28 / 24 / 11 pass |
| `test/v12/s3_qa` (matrix incl. the unskipped text-style check, flag-off guard, 5k scroll), flags off | **22 pass, 0 skip** (the text-style check: 0 fallback texts) |
| `test/v12/wiring/s3_wiring_test.dart test/v12/s3_qa` with `DANAVIEW_FILES_HOME=true` | 35 pass, 5 skip (flag-off tests) |
| `test/v12/s2_qa/s2_matrix_test.dart` | 10 fail at `tapKey('file-info')`: FIX-S3Q-3 still open (low, test only) |
| HOM-15 (`scripts/ci/v12/home_preservation.sh -j 1`) | **406 pass** |
| S3 E2E (`integration_test/v12/s3/s3_documents_test.dart`, as §2) | every step passes, incl. the new FIX-S3Q-1 steps; **the run fails at the end on FIX-S3Q-7** (below) |

FIX-S3Q-1 on the simulator: the Documents row menu is Open, Rename…, Move to…, **More actions…**,
Delete (`s3-04`); More actions… opens HOM-22's menu with Share, Open in another app, Save out
(Save to Files), Copy to, Move to, Rename, Favourite, File info, Delete (`s3-04b`); File info
opens (`s3-04c`); the PDF viewer's top-bar "File actions" offers Share, Copy to, File info, Open in
another app, Favourite, Save to Files, and its Share hands over the library file, byte-equal
(`s3-07b`). **Fixed.**

FIX-S3Q-2 on the simulator: the PDF chrome, text viewer, CSV grid, file card and the menus draw in
Figtree with the kit weights; no yellow underline anywhere (`s3-05`, `s3-09`, `s3-10`, `s3-11`).
**Fixed.**

FIX-S3Q-6: S3-W's flag-off guard (iOS and macOS) now has a default-on check in
`s3_flag_off_incoming_test.dart` (10 pass: per OS, videos play, PDF / JPEG / docx / txt show
"Danaview can't open this kind of file." and never reach the player). **Fixed for the Dart path**;
Share Extension batches with the flag off stay as S3-W noted (owner).

5,000-document scroll (`s3_documents_scroll_test.dart`, 375 × 812): rows built stay under 60 at the
top, after a jump to the end and through a fling; the PDF sub-filter narrows to a fifth; no
exceptions. Jumping straight to the end takes ~5 s in test mode, because `SliverList.builder`
without an item extent lays out every row on the way (N-S3-5).

### New defects

| Id | Owner | Defect | Evidence | Fix direction |
|---|---|---|---|---|
| **FIX-S3Q-7** | S3-W (`lib/wiring/documents_wiring.dart`) with HOM-21 (`SystemOpenInCopyRoots`, `danaview_player_actions.dart`) | Regression since the first run: an Open with copy in `Documents/Inbox` is no longer removed after the import. The HOM-21 fix round made `SystemOpenInCopyRoots.current` default to `$HOME/Documents` on iOS, but `HOME` is empty in the app's Dart environment and nothing calls `SystemOpenInCopyRoots.configure`, so every path counts as the user's and iOS's copies pile up in the container | E2E: "Open with: iOS's Documents/Inbox copy not removed after the import (isSystemOpenInCopy false, HOME set false)" | At boot (flag on, iOS) call `SystemOpenInCopyRoots.configure(SystemOpenInCopyRoots.ios(documentsDirectory: getApplicationDocumentsDirectory(), temporaryDirectory: getTemporaryDirectory(), bundleId: …))`; also in `E2eApp._boot`; S3-Q re-runs the E2E |
| **FIX-S3Q-8** | HOM-23 (`danaview_documents/lib/src/text/csv_viewer.dart` / `csv_table.dart`) | The CSV grid leaves a gap the height of the status bar between the header row and row 1 (owner rule: no big gaps); the rows' list seems to pick up `MediaQuery.padding.top` | `s3-10-csv-viewer` (≈ 60 pt empty band under the header) | Give the row list an explicit `EdgeInsets.zero` padding (or `MediaQuery.removePadding(removeTop: true)`); add a test that row 1 sits right under the header |

Notes: N-S3-5 (low, HOM-18): for scrollbar or scroll-to-top jumps over thousands of rows, give the
Documents (and All / Folders) row lists a `SliverPrototypeExtentList` or `itemExtentBuilder`.
N-S3-6 (low, S3-W): `lib/main.dart`'s comment "Nothing with the flag off" above
`installIncomingDocumentOpen` is stale since the flag-off guard.

### Document test-pass checklist (manual, per platform)

1. Import from Files: PDF, docx, xlsx, pptx, txt, csv, zip; each lands in Imported, kind document / other.
2. Documents tab: sub-filters narrow; rows show size · date (· pages for PDF); no overflow at 280 px × 1.35.
3. Row menu: Open, Rename…, Move to…, More actions…, Delete; More actions… → Share, Save out, Copy to, Favourite, File info, Open in another app all work.
4. PDF: first page, search, page thumbnails, annotations visible; top bar File actions → Share, Save out, File info.
5. Text / CSV / Office: Quick Look (Apple) or the in-app viewer; UTF-8 and non-Latin text; CSV quoted commas and newlines; no gap under the header.
6. Unknown file: file card with Share and Open in another app.
7. All viewers: Figtree, no yellow underline, no hover/press effects, Back returns to the list.
8. Open with Danaview from Files: imported once, viewer shown, the system Inbox copy removed; the same file again opens the existing entry.
9. Share Extension (iOS) / `ACTION_SEND` (Android): items land in the chosen folder, toast, interrupted batch ignored.
10. Flag off: documents and photos opened with Danaview show the neutral toast; videos play as in 1.1.
11. Relaunch: entries, favourites and Recents persist; originals unchanged; no network.

### Verdict (Mac half, re-check)

**Red.** Both original blockers are fixed (FIX-S3Q-1, FIX-S3Q-2), FIX-S3Q-6 is fixed for the Dart
path, and every suite above passes, but the S3 E2E fails on the new regression FIX-S3Q-7 and the
screenshots show FIX-S3Q-8. Still open, low: FIX-S3Q-3, FIX-S3Q-4, FIX-S3Q-5, D-S3W-1, D-S3W-2 (since fixed: FIX-S3Q-3 `c8853faf`,
FIX-S3Q-4 `cc2d6e12`, FIX-S3Q-5 `6f2684ac`, D-S3W-2 `cdf3c313`; D-S3W-1 by HOM-21A `8ebb2094` / `a61160de`).
Android half: **pending: Windows**.

## Release candidate

Ticket **S3-R**, Mac half, on `v1.2-wip`, 2026-10-23, 15:22–15:35. Build tree: `2ae2b294`, code clean
(only this report modified). Nothing was signed, uploaded or changed in the signing settings; the
version files were not touched (`pubspec.yaml` `1.0.0+1`). **The candidate carries the open S3-Q
re-check defects FIX-S3Q-7 and FIX-S3Q-8** (§Re-check, verdict Red): it is a build and packaging check,
not a release go; rebuild on the commit that closes them.

### iOS release build

```text
LANG=en_US.UTF-8 flutter build ipa --release --no-codesign --build-name=1.0.0 --build-number=1 \
  --dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true \
  --dart-define=DANAVIEW_FILES_HOME=true --dart-define=DANAVIEW_PHOTO_EDITOR=false \
  --dart-define=DANAVIEW_BEAUTY=false --dart-define=DANAVIEW_AI_STUDIO=false
```

The S2-R flag set (S3 adds no flag). `WhisperCore.xcframework` `--status` = up-to-date, used as is;
nothing rebuilt or downloaded.

| Check | Result |
|---|---|
| Build | **pass**, archive 224 s: `build/ios/archive/Runner.xcarchive` (264.0 MB with dSYMs; S2 253.5 MB); `--no-codesign` skips the IPA export |
| Info.plist (archived `Runner.app`) | `1.0.0` / `1`, `MinimumOSVersion 15.0`, `com.vecvel.danaview`; `NSPhotoLibraryUsageDescription` and `NSPhotoLibraryAddUsageDescription` the S2 texts; `LSSupportsOpeningDocumentsInPlace true` |
| Document types (flag on, after the "Gate Files Home declarations" phase) | all five: Video Media **Owner**; Image, PDF Document, Office Document (16 UTIs), Text Document (plain text, CSV, TSV, JSON, Markdown, log) **Alternate** |
| Share Extension | `PlugIns/DanaviewShare.appex` embedded (172 KB): `com.vecvel.danaview.share`, `1.0.0` / `1`, min 15.0, `com.apple.share-services`, activation rule images, movies, PDF, Office/iWork, text, delimited text, JSON |
| App Group entitlement | not in the unsigned bundle (`--no-codesign` embeds none); the sources both targets sign with declare `group.com.vecvel.danaview`: Runner `CODE_SIGN_ENTITLEMENTS` → `Runner/Runner.entitlements` (`DANAVIEW_BG_GPU_ENTITLEMENT = NO`; the GPU variant carries the group too), extension `DanaviewShare/DanaviewShare.entitlements`; `InboxWriter.swift` uses the same id. Confirm on the signed archive (`codesign -d --entitlements -`, checklist item 8) |
| `check_ios_min_os.sh --min 15.0` on the archived `Runner.app` | **OK**: 30 binaries (S2 28), 1524 strongly bound symbols probed (S2 1458), weak allowlist BackgroundTasks |
| `nm -um` `NEWLAPACK` on `Runner`, `Frameworks/*` and the appex | none |
| Privacy manifests | app and `DanaviewShare.appex` (both FileTimestamp `C617.1`, DiskSpace `E174.1`, no tracking, no collected data), `danaview_library_native` (S2 fix), Flutter, danaview_whisper, danaview_editor_engine, file_selector, shared_preferences, wakelock_plus, package_info_plus. **`danaview_pdf` ships none**: its binary and sources reference no required-reason API (`nm -um` and source grep: no file timestamps, disk space, user defaults, uptime), so none is required; `danaview_documents` is Dart only (no pod). The appex references `NSURLVolumeAvailableCapacityForImportantUsageKey`, covered by its `E174.1` |
| Flutter warning | launch image is the default placeholder (as in S1/S2; owner asset) |

**Size** (unsigned, archive's `Runner.app`, same method as S2):

| Measure | S2 candidate | S3 candidate | Delta |
|---|---|---|---|
| `Runner.app` on disk | 63.8 MB (65 324 KB) | **66.1 MB (67 736 KB)** | +2.4 MB (+3.7 %) |
| `Payload/Runner.app` zipped (`zip -9`) | 25.1 MB (25 076 450 B) | **26.1 MB (26 066 864 B)** | +0.99 MB (+3.9 %) |
| S3 parts | App 23.0 MB, `danaview_pdf` 92 KB | App 23.3 MB, `danaview_pdf` 732 KB, `DanaviewShare.appex` 172 KB | App +0.3 MB, native +0.8 MB |

### Install and smoke on the iOS Simulator (iPhone 16, iOS 26.5)

Debug simulator build of the same tree, version and defines (`flutter build ios --simulator --debug`,
84 s; release can't run on a simulator), fresh install; `s3_report.pdf`, `s3_shared.pdf` and
`s3_table.csv` from `build/e2e/s3_docs/` (`make_s3_docs.sh`, local) copied into Files › On My iPhone.
Driven by hand, every system sheet real:

| Step | Result |
|---|---|
| Launch | pass: Home with Home, All, Videos, Photos, **Documents**, Playlists, Folders; no prompt |
| Import a PDF and a CSV | pass: Import › From Files (system picker, multi-select) › both "Imported" |
| Documents tab | pass: sub-filters All documents, PDF, Word, Excel, PowerPoint, Text/CSV, Other; rows `s3_table.csv 14 KB · 23 Oct 2026`, `s3_report.pdf 274 KB · 23 Oct 2026` with a page thumbnail. No page count on the PDF row (N-S3R-1) |
| Open the PDF | pass: PDFKit viewer, "Page 1 of 200", search, thumbnails and the file-actions buttons in the top bar; Back returns to the list |
| Open the CSV | pass: "Showing the preview." then Quick Look (about 2 s): header row, `Zürich`, `São Paulo`, quoted `has, comma` and the multi-line cell in one cell; closing returns to the app |
| Share Extension from Files | pass: Files › long-press `s3_shared` › Share › **Danaview** › "Save to Danaview · 1 item · choose a folder" (Imported checked) › Save; back in Danaview the Documents tab lists `s3_shared.pdf 6.4 KB`, and the App Group holds only `folder-snapshot.json` afterwards (the batch was moved and removed). The picker's folder list leaves a large empty panel under a single row (N-S3R-2) |
| Rule 30 | pass: of the session's 2 168 log lines, the 10 naming a test file are iOS's own (file coordination, DocumentManager, Quick Look); none from Flutter or the extension's code |

The simulator was booted for this step and shut down after it. Device smoke of the signed build
(iPhone 12, iPhone 7 iOS 15.8, iPhone 8 iOS 16.7): deferred: no device available.

### Android candidate

Windows / Android lane, 2026-10-23, 17:29–17:50, on `66595c4f` (= the S3 gate tree plus
`origin/v1.2-wip` `e9e6eeba` with 14dc89fe and `origin/hom21a-android` `8e02dd93`; clean, version
`1.0.0+1` already in the tree). Nothing was signed, uploaded or changed in the signing settings; there
is no `android/key.properties`. Built alone (no `flutter test` in the tree at the same time).

```text
flutter build appbundle --release --build-name=1.0.0 --build-number=1 \
  --dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true \
  --dart-define=DANAVIEW_FILES_HOME=true --dart-define=DANAVIEW_PHOTO_EDITOR=false \
  --dart-define=DANAVIEW_BEAUTY=false --dart-define=DANAVIEW_AI_STUDIO=false
# then `flutter build apk --release` with the same arguments (smoke), and once with
# DANAVIEW_FILES_HOME=false (flag-off check)
```

| Check | Result |
|---|---|
| Build | **pass**: AAB 304 s, fat APK 112 s, flag-off APK 131 s; copies in `build/s3_android/release/` |
| Signing | debug key (`CN=Android Debug`), as expected without `key.properties` |
| `check_native_libs.sh` on the AAB | **all checks passed** (16 KB alignment, Whisper libraries and their 24 `dv_*` exports, no `libc++_shared.so`, sizes) |
| Version (`aapt2 dump badging`) | `versionName 1.0.0`, `versionCode 1`, `com.vecvel.danaview`, targetSdk 36, compileSdk 36; native code arm64-v8a, armeabi-v7a, x86_64 |
| Permissions | unchanged from S2 (S3 adds none) |
| Manifest (`aapt2 dump xmltree`) | `.IncomingDocumentsAlias` (target `.MainActivity`, exported) carries the VIEW / SEND / SEND_MULTIPLE document, text and image filters (D-S3W-1); `android:enabled=true` in the flag-on build, `false` in the flag-off build, the only difference between the two manifests |
| Third-party code | PdfBox-Android 2.0.27.0 (HOM-25) is in the build: FIX-S3Q-A2 |

**Size** (debug-signed; Play's per-device sizes come from the console after upload):

| Measure | S2 candidate | S3 candidate | Delta |
|---|---|---|---|
| `app-release.aab` | 101.0 MB (105 869 493 B) | **108.2 MB (113 460 081 B)** | +7.2 MB (+7.2 %) |
| Native libraries per ABI in the AAB (uncompressed) | arm64-v8a 41.3, armeabi-v7a 35.5, x86_64 44.7 MB | arm64-v8a 41.7, armeabi-v7a 35.9, x86_64 45.2 MB | about +0.4 MB per ABI (S3 Dart in `libapp.so`) |
| PdfBox-Android resources (`com/tom_roush/pdfbox/…`) | — | 4.4 MB | new (plus its classes in the dex) |
| Fat release APK (smoke only) | 128.0 MB | 135.2 MB (141 714 355 B) | +7.1 MB |

**Install and smoke** of the release APK on Pixel_9_Pro_XL_API_35 (`emulator-5554`), fresh install,
the S3 documents pushed to `Download/S3QA` and media-scanned, `POST_NOTIFICATIONS` pre-granted. Driven
with `adb input` + `uiautomator dump`, every system UI real (DocumentsUI, the share sheet, the Open
with chooser, the share resolver). Screenshots `build/s3_android/smoke/r01…r14`.

| Step | Result |
|---|---|
| Launch, Files home | pass: tabs Home, All, Videos, Photos, **Documents**, Playlists, Folders, Projects; search with the + Import button; no prompt (`r01`) |
| Share in from Files (**ACTION_SEND_MULTIPLE**): Files › Download › S3QA › select `s3_shared.jpg` + `s3_shared.pdf` › Share › "Sharing 2 files" › **Danaview** | pass: Danaview opened at Home with the toast "2 shared items saved"; both in Imported, the photo under Recent photos (`r02`, `r03`) |
| Open with from Files (**ACTION_VIEW**): tap `s3_openwith.pdf` › Open with (Danaview, Drive PDF Viewer, Drive) › Danaview › Just once | pass: imported, PDF viewer "Page 1 of 3" (`r04`, `r05`) |
| Import From Files (in-app, DocumentsUI) and open the PDF | pass: `s3_report.pdf` imported; Documents tab lists the three PDFs (`r06`); viewer "Page 1 of 200" (`r07`) |
| PDF search | pass: `HOM27T-P0150` → "1 of 1 match", jumps to "Page 150 of 200" (`r08`) |
| Share text in (**ACTION_SEND text/plain**, implicit, from the shell): the resolver lists Danaview › Just once | pass: `Shared text 2026-10-23 1745.txt` (31 B, 8e02dd93's name) in All; opens in the text viewer, "UTF-8 · 1 line", the shared text shown (`r09`–`r11`) |
| Rule 30 | pass: the app's logcat for the session (265 lines) names none of the shared or imported files |
| **Flag-off build** (`DANAVIEW_FILES_HOME=false`, same tree, fresh install) | pass: the 1.1 Home (Open file / folder / link, Playlists, Folders; no tabs, no Documents) (`r12`); `cmd package query-activities`: VIEW of PDF / JPEG / text, SEND of PDF / JPEG / text / video, SEND_MULTIPLE PDF → **no Danaview**; VIEW `video/mp4`, VIEW `audio/mpeg`, `danaview://` → `.MainActivity` (`flagoff_query_activities.txt`); Files › tap a PDF opens Drive's viewer directly (Danaview not offered, `r13`); Files › tap an MP4 › Open with › Danaview opens the 1.1 player (`frame_counter_720p24.mp4`, 00:00 / 00:08, `r14`) |

Not done: `bundletool build-apks` from the AAB (the APK of the same tree stood in), API 34 / 29 / 28
smoke (HOM-21A's instrumented tests ran there), the device smoke of a signed build (owner / lab).

### Release checklist (S3)

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | Gate: S3-Q Mac half green; Android half | S3-W / HOM-21 / HOM-23, Windows | **open**: re-check Red on FIX-S3Q-7, FIX-S3Q-8; Android half **green** (§7, `88c0c1c9` / `66595c4f`; D-S3W-1 fixed by HOM-21A; FIX-S3Q-A1/A2 low) |
| 2 | Version `1.0.0+1` (never bumped) | S3-R | **done** (in the tree) |
| 3 | iOS release build with the S1–S3 flag set, Info.plist, document types, appex, min-OS, `NEWLAPACK`, privacy manifests, size | S3-R | **done** (above) |
| 4 | Simulator install and smoke | S3-R | **done** (debug build) |
| 5 | Rebuild and re-smoke on the commit that closes FIX-S3Q-7/8 (the Inbox-copy cleanup is visible only after Open with, not covered by this smoke) | S3-R | open |
| 6 | Signing: **two App IDs with the App Group `group.com.vecvel.danaview`** (`com.vecvel.danaview`, `com.vecvel.danaview.share`; `ios/fastlane/SHARE_EXTENSION.md`), S1 §Signing commands with `DANAVIEW_FILES_HOME=true`; check both signed entitlements; fastlane still blocked by FIX-S1R-1 | **owner** | open |
| 7 | Device smoke incl. the Share Extension under the extension memory limit, Open with from Files and Mail, iOS 15–17 | owner / lab | deferred: no device available |
| 8 | Upload (internal until the owner's go); privacy report from the signed archive (app + extension: FileTimestamp, DiskSpace; no data collected) | **owner** | open |
| 9 | `legalEffectiveDate`; hosted privacy page regenerated from a flag-on build (the S3 blocks exist only there); owner review of the S3 wording | **owner** | open |
| 10 | Store answers: App Privacy unchanged, the App Review note for the share sheet and documents (§Wiring "Store-answer deltas") | **owner** | open |
| 11 | Android release build and emulator smoke | Windows lane | **done** (debug-signed AAB of `66595c4f`, native-lib checks pass, smoke on API 35 green incl. real Files share / Open with / text share, flag-off build offers no document intents; tablet grids §7.3; see "Android candidate") |

### Notes (S3-R)

- N-S3R-1 (low, HOM-18 / HOM-23): the Documents row of a PDF shows `size · date` without the page
  count the test-pass checklist (item 2) expects; say if pages should show there.
- N-S3R-2 (low, INT-104, owner rule "no big gaps"): the extension's folder picker draws a full-height
  bordered panel even with one folder; size the list to its rows.

**S3-R Mac verdict:** the iOS candidate (`2ae2b294`, `1.0.0+1`, S1–S3 flags) builds in release with all
five document types, the embedded Share Extension and both privacy manifests, passes the 15.0 min-OS and
`NEWLAPACK` checks, grows 2.4 MB on disk / 0.99 MB zipped over S2, and smokes green on the iPhone 16 /
iOS 26.5 simulator (Documents tab, PDF, CSV via Quick Look, Share Extension from Files). **Not a
release candidate yet**: the S3 gate is Red (FIX-S3Q-7, FIX-S3Q-8); rebuild after those close. Signing
with the App Group, upload and the store answers are the owner's; Android is the Windows lane.

## Final Mac-half verdict (2026-10-23, lead)

**Green.** FIX-S3Q-7 (iOS Open-in copies not cleaned up) and FIX-S3Q-8 (status-bar-tall gap under
the CSV header) fixed in `2351545`. The S3 E2E
(`integration_test/v12/s3/s3_documents_test.dart`, iPhone 16 / iOS 26.5) passes 1/1 end to end,
including reopen, originals unchanged (8 files) and no HttpClient. The CSV screenshot shows the
rows right under the header in Figtree. One earlier run failed mid-run at a list scroll
(`_reveal`, "No element" while the list rebuilt); it passed on the clean re-run, so it's recorded
as a flaky harness step (low).

**Release candidate (Mac half), rebuilt on `ab252f2` (the fixed tree):**
- `flutter build ipa --release --no-codesign` with DANAVIEW_EDITOR, DANAVIEW_AUTO_CAPTIONS and
  DANAVIEW_FILES_HOME true (PHOTO_EDITOR, BEAUTY, AI_STUDIO false): archive 264.0 MB, zipped app
  26.06 MB (S2: 25.08 MB, +0.98 MB).
- Version 1.0.0 (1), minimum iOS 15.0; DanaviewShare.appex embedded.
- check_ios_min_os: OK. NEWLAPACK: none.
- Not signed or uploaded. The App Group entitlement is checked on the owner's signed archive.

**Android half:** HOM-25 and HOM-21A (with the flag-gated activity-alias) merged into v1.2-wip.
The S3-Q and S3-R Android halves are pending on Windows.

Still open, low: FIX-S3Q-3..5, N-S3-5/6, N-S3R-1 (no PDF page count on its row), N-S3R-2
(the Share Extension folder picker's empty panel), D-S3W-2 (the player menu "Save to Danaview
folder" item needs its one-line hook in danaview_controls_overlay.dart). Recommended for S4's
first round.
