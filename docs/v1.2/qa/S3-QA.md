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
| Player "Save to Danaview folder" (HOM-21) | HOM-21's `canSaveToDanaviewFolder` / `saveToDanaviewFolder` exist but no player menu calls them yet (see D-S3W-2) | open (HOM-21) |
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
- With the flag off the app is the S1 app (S3 test "flag off", S2 test "flag off", INT-101's
  `flags_off_test.dart`).

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
| Google Play permissions | None added by S3: incoming `VIEW` / `SEND` / `SEND_MULTIPLE` intents need no permission. The filters are not in the manifest yet (D-S3W-1) |

### Tests (S3-W)

`test/v12/wiring/s3_wiring_test.dart` (18 tests, green plain and with
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

### Defects and open items

| # | Item | Owner | Status |
|---|---|---|---|
| D-S3W-1 | `android/app/src/main/AndroidManifest.xml` has none of INT-104's Android intent filters (`application/pdf`, Office MIME types, `text/*`, `image/*` on `VIEW` / `SEND` / `SEND_MULTIPLE`), so on Android no document or image can be opened with or shared to Danaview; HOM-21A needs them | INT-104 (Android part, Windows lane) | defect |
| D-S3W-2 | HOM-21's "Save to Danaview folder" (`canSaveToDanaviewFolder`, `saveToDanaviewFolder` in `danaview_player_actions.dart`) is not offered by any player menu (`danaview_player_screen.dart` / the controls overlay do not call it) | HOM-21 | open |
| D-S3W-3 | `test/v12/s2_qa/s2_matrix_test.dart` (S2-Q) walks "document file menu → File info" by tapping a document row; from S3 that opens the viewer router (10 matrix tests fail at `tapKey('file-info')`). The step should open File info from the file card or the row menu, or move to S3-Q's matrix | S2-Q / S3-Q | defect (test only) |
| D-S3W-4 | HOM-18's `documentsFilterShown` stays `false` and its tests pin it; the app shows Documents through `s3DocumentsShown`. HOM-18 may flip its constant (and `filters_test.dart`) so the package default matches the shipped app | HOM-18 | open, low |
| D-6 (S2) | The features barrel still exports none of the Files & Media Home surfaces; both wiring files use `implementation_imports` | INT-101 (barrel) | open, low |
| — | `legalEffectiveDate`, the owner's review of the S3 wording, regenerating the hosted privacy page from a build with the flag, App Group on both App IDs before signing | S3-R with the owner | open |
