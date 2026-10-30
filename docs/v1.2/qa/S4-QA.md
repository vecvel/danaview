# S4 · Documents: PDF tools: gate report

Slice S4 of 1.2.0 (BUILD_PLAN v1.2 §1A). The gate has three tickets: S4-W (wiring and legal,
§Wiring below), S4-Q (slice QA, the sections it adds below §Wiring) and S4-R (release candidate).
S4-W edits only §Wiring.

## Wiring

Ticket **S4-W**, Mac lane, branch `s4-w` from `v1.2-wip` (every S4 Mac half: HOM-28, HOM-29,
HOM-30, HOM-31; Android HOM-28A and HOM-31A merged), 2026-10-30. No feature work: the S4 tools
were wired by their own tickets behind `DANAVIEW_FILES_HOME` (default false, never flipped in
code); S4-W audits that wiring from the app root, fixes the one entry point that was not reached,
adds the slice's privacy, terms and licence text, the store-answer deltas, and fixes the iOS
output-ownership bug the Windows lane reported. Integration rights: the slice's share of INT-103
(app root) and of INT-106 (privacy and terms).

### Files

| File | Change |
|---|---|
| `lib/wiring/files_home_wiring.dart` (`// EXTENDED: S4-W`) | **Fix:** the selection bar's file group was always `fileSelectionGroup` (no Merge into PDF), so the multi-select "Merge into PDF" that HOM-28 wired (`mergeIntoPdfHandlerProvider`) was never offered. `selectionActionGroupsProvider` now watches the handler and uses `fileSelectionGroupMerging` (`fileSelectionGroupWith(canMerge: true)`, one instance) once merge is wired; otherwise the S2 list exactly |
| `lib/wiring/documents_wiring.dart` (`// EXTENDED: S4-W`) | `documentViewerSetupFor(…, pdfView:)`: the PDF viewer's native view as a test seam (no behaviour change) |
| `packages/danaview_features/lib/src/more/legal_texts.dart` (`// EXTENDED: S4-W`) | S4 privacy and terms text, only in builds with the flag (below); the S3 terms sentence now reads "viewing never changes them" so it stays true next to Replace |
| `packages/danaview_features/lib/src/more/danaview_licenses_screen.dart` (`// EXTENDED: S4-W`) | PdfBox-Android's entry names the PDF tools and carries Apache PDFBox's NOTICE; Bouncy Castle's use names protected tool results |
| `android/app/src/main/res/xml/danaview_backup_rules.xml`, `danaview_data_extraction_rules.xml` (`EXTENDED: S4-W`) | `<exclude domain="file" path="signatures"/>` in Auto Backup (API ≤ 30), cloud backup and device transfer (API 31+): the saved signatures (`filesDir/signatures`) are never backed up, as the privacy text says (HOM-30A's contract item, done here so the text is true on every platform before Android signs) |
| `packages/danaview_editor_core/test/store/gc/backup_rules_test.dart` (`EXTENDED: S4-W`) | CORE-28's full rule list gains the signatures rule (6 → 8 file rules in the API 31+ file) |
| `packages/danaview_pdf/darwin/Resources/PrivacyInfo.xcprivacy` (new), `danaview_pdf.podspec`, `ios/Podfile.lock` | **Store fix:** the pod had no privacy manifest while the S4 tools call required-reason APIs (`attributesOfItem`: file timestamp C617.1; `volumeAvailableCapacity`: disk space E174.1). Bundled as `danaview_pdf_privacy`, as FIX-S2R-1 did for `danaview_library_native`; the iOS lock's checksum follows the podspec (`macos/Podfile.lock` was already stale for both pods and is left to the next macOS `pod install`) |
| `packages/danaview_pdf/darwin/Classes/Tools/PdfNewFiles.swift` (new), `Tools/PdfPageToolsCore.swift`, `Annotate/PdfAnnotateCore.swift`, `Compress/PdfCompressCore.swift` (`EXTENDED: S4-W`) | **iOS fix** (Windows lane report): outputs are created exclusively and only the job's own files are deleted (below) |
| `packages/danaview_pdf/darwin/Tests/Tools/Core/PdfOutputOwnershipTests.swift` (new), `Tests/Compress/PdfCompressCoreTests.swift`, `Tests/Viewer/run_xctests.sh`, `Tests/Compress/run_compress_xctests.sh` | XCTests of the fix; the runners compile the new helper |
| `test/v12/wiring/s4_wiring_test.dart`, `test/v12/legal/s4_pdf_tools_text_test.dart` (new) | Gate tests |

### What is wired (flag on)

Every entry point appears only where the platform's `danaview_pdf` reports the tool
(`PdfDocuments.capabilities().tools` for the viewer and Compress, `PdfPageTools.supported()` for
the handlers; the same native list). **Android today** reports merge, split, reorder, rotate,
deletePages (HOM-28A) and compress (HOM-31A); `PdfAnnotator.supported` and `PdfSigner.supported`
are still empty, so Annotate, Sign, "Sign…" and the Settings rows stay hidden there until HOM-29A /
HOM-30A report them. Windows and Linux have no `danaview_pdf`: no tools, PDFs open on the file card.

| S4 surface | Where it is reached | iOS / macOS | Android now | Android + 29A/30A | Windows / Linux | Status |
|---|---|---|---|---|---|---|
| Viewer: Organise pages | `openDocumentViewer` → `withPdfTools` → `PdfToolsScope`; top bar `pdf-viewer-organise` (`canOrganise`) | shown | shown | shown | — | done |
| Viewer: Annotate | top bar `pdf-viewer-annotate` (engine `annotate` + tool reported) | shown | hidden | shown | — | done |
| Viewer: Sign | top bar `pdf-viewer-sign` ("Sign…" in the menu under 360 pt) | shown | hidden | shown | — | done |
| Viewer: Merge with… | viewer menu (merge reported and the library picker) | shown | shown | shown | — | done |
| Viewer: Compress… | viewer menu (`documentViewerSetupFor(compress: pdfCompressLauncher)`) | shown | shown | shown | — | done |
| File menu: Organise pages, Merge with… | `pdfPageToolsHandlerProvider` (`canOrganise` + merge) | shown | shown | shown | — | done |
| File menu: Compress… | `compressPdfHandlerProvider` (`pdfCapabilitiesProvider` lists compress) | shown | shown | shown | — | done |
| File menu: Sign… | `signPdfHandlerProvider` (opens the viewer in sign mode) | shown | hidden | shown | — | done |
| Multi-select: Merge into PDF | `selectionActionGroupsProvider` → `fileSelectionGroupMerging` (PDFs and photos, 2+) | shown | shown | shown | — | **fixed in S4-W** (was never offered) |
| Settings › Privacy: saved signatures | `appSettingsSectionsFor` → `SavedSignaturesPrivacyRows` (store wired and sign reported) | shown | hidden | shown | — | done |
| Saved-signature store | `signatureStoreProvider` = `FileSignatureStore` in `<app support>/signatures` (beside the library root, backup-excluded through `NativeBackupFlags` on Apple, the backup rules on Android) | yes | yes (unused until 30A) | yes | none | done |

Providers checked: `pdfToolsEngineProvider`, `pdfToolsSupportedProvider`, `pdfToolsEnvironmentProvider`,
`signatureStoreProvider`, `signaturePhotoPickerProvider` (`pdf_tools_wiring.dart`);
`pdfCapabilitiesProvider`, `pdfCompressEngineProvider`, `documentViewerSetupProvider`
(`documents_wiring.dart`); the four handler providers of `danaview_features`. All are composed by
`documentsOverrides` → `pdfToolsOverrides` inside `filesHomeOverrides`, so `lib/main.dart` needs
nothing new.

**Features barrel and `implementation_imports`:** as S2/S3 (D-6 below): the wiring files and the
gate tests reach the S4 providers through their `lib/src/` entry files with
`// ignore_for_file: implementation_imports`; the features barrel stays unchanged (INT-101).
`danaview_pdf` stays out of `danaview_features` (rule 23; `test/architecture` green).

### Flag set of the S4 build

- S4-R passes `--dart-define=DANAVIEW_FILES_HOME=true` plus the v1.1 release defines
  (`DANAVIEW_EDITOR`, `DANAVIEW_AUTO_CAPTIONS`); `DANAVIEW_PHOTO_EDITOR`, `DANAVIEW_BEAUTY`,
  `DANAVIEW_AI_STUDIO` stay off. S4 adds no flag: the PDF tools ride on `DANAVIEW_FILES_HOME`
  and on each platform's reported tools. Version stays **`1.0.0+1`**; FIX-S1R-1 (no dart-defines
  in the fastlane lanes) still applies.
- With the flag off the S4 Dart side is absent (`s4_wiring_test` "flag off": no override on any
  platform, every handler null, the selection bar has only the media group, no tools scope, no
  Settings rows). The native tools are in every build (the `danaview_pdf` plugin since S3), but
  nothing calls them without the flag.

### Privacy policy, terms and licences

`legal_texts.dart` gets four constant blocks that join the documents through
`if (FeatureFlags.filesHome)`, right after the S3 blocks:

- **What Danaview stores on your device** (`pdfToolsStoredBullets`): *Saved signatures* — a picture
  only on this device, in the app's private storage, not in the Danaview folders, not shown in
  other apps, not in backups and not moved to a new device; up to 10; delete one while signing or
  all in Settings › Privacy; a picked photo is only used to make the picture and then deleted.
- **Files and permissions** (`pdfToolsPermissionBullets`): *PDF tools* — Organise pages, Merge,
  Annotate, Sign and Compress run entirely on the device and upload nothing; results are new files
  next to the original (Imported for files from elsewhere), the original never changed; only Replace
  for a Danaview folder PDF overwrites it; a signature is a picture, not a certificate-based digital
  signature; a signature photo comes through the system photo picker (the file picker on Mac).
- **Your choices** (`pdfToolsChoiceBullets`): delete saved signatures while signing or all in
  Settings › Privacy.
- **Terms of Use:** new section "PDF tools and signatures" after "Documents" (new files unless
  Replace; a visual signature, Danaview doesn't verify who signed; sign only what you may sign).
  The S3 "Documents" sentence now says "viewing never changes them".
- No host is named and none is added (ARCH v1.2 §9.1: the tools are offline). `legalEffectiveDate`
  stays with the owner at S4-R.
- **Licences:** PdfBox-Android (Apache-2.0, FIX-S3Q-A2) is confirmed on the licences screen in
  every build (the plugin ships in every Android build since S3); S4-W adds its use by the PDF
  tools and **Apache PDFBox's NOTICE** (Apache-2.0 §4 d; text from PdfBox-Android's `NOTICE.txt`,
  plus the AAR's Liberation Sans OFL font and Adobe resources, as `LICENSE-THIRD-PARTY.md` lists
  them). Bouncy Castle (MIT) stays. **Signature fonts:** Caveat, Pacifico and Playfair Display are
  the bundled OFL content fonts of `danaview_editor_fonts`; `registerAppLicenses` already registers
  their OFL text in every build ("<family> (video editor content font)"), so no new entry is
  needed. Nothing new is downloaded (typed signatures use bundled fonts only).

### Store-answer deltas (for S4-R and AIS-41)

| Store item | S4 delta |
|---|---|
| App Store App Privacy | Unchanged: "Data Not Collected". No new data type: PDFs are processed and saved on the device; saved signatures are images in app-private storage, never sent anywhere |
| Privacy manifests | **New:** `danaview_pdf` bundles `PrivacyInfo.xcprivacy` (file timestamp C617.1, disk space E174.1; no tracking, no collected data). The app's `ios/Runner/PrivacyInfo.xcprivacy` already declares both categories. Check inside the S4-R `Runner.app` (`danaview_pdf_privacy.bundle`) |
| App Store review note | Add: "PDF tools (organise pages, merge, annotate, sign, compress) run on the device and save new files. Signatures are images placed on the page (not certificate-based digital signatures) and are stored only on the device, excluded from backups." |
| Export compliance | Unchanged from S3 (owner to confirm at S4-R): an encrypted PDF's tool result is written encrypted with the user's own password through PDFKit / PdfBox-Android's standard PDF security; Danaview adds no cryptography of its own |
| Google Play Data safety | Unchanged: no data collected or shared |
| Google Play permissions | None added by S4 (the signature photo comes through the photo picker) |
| Android backup | `files/signatures` excluded from Auto Backup, cloud backup and device transfer |

### iOS fix: the PDF tools delete only files they created (Windows lane report)

`PdfPageToolsCore.write` checked "output exists" late and threw, and `writingNewFiles` then
deleted every output path it was given; compress wrote with `.withoutOverwriting` and removed
`outPath` on any failure. In a race (another writer's file appearing at the output path after the
early check) that deleted someone else's file. Now (as Android: `createNewFile()` + `Outputs.created`):

- `PdfNewFiles` (`Classes/Tools/PdfNewFiles.swift`) claims each output with `open(O_CREAT | O_EXCL |
  O_RDONLY)` before anything is written (no source is opened for writing: rule 27 holds), records
  it, and deletes only claimed paths; an existing file fails with `invalidArgument` "output exists"
  and is never touched.
- `writingNewFiles { files in … }` and `write(…, files:)` (merge, split, organise, annotate and
  sign through it) delete only `files.created` on cancel or failure; split removes its own earlier
  parts and leaves the raced path alone. Compress claims `outPath`, then writes into its own file.
- XCTests (`PdfOutputOwnershipTests`, 6; `testAFileThatAppearsAtTheOutputIsNeverDeleted` in
  compress): the claim helper; a file that appears right before the write of merge, organise,
  split's second part, annotate and burn-in sign, and compress keeps its bytes and the job fails
  `invalidArgument`; a normal write still produces the file (PDFKit writes over its own claim).
  Run against the old cores (a scratch copy), the race tests fail: the other file is deleted
  (merge, organise, annotate, sign, compress; compress also answered `ioError`).

### Tests (S4-W)

`test/v12/wiring/s4_wiring_test.dart` (8 tests, green plain and with
`--dart-define=DANAVIEW_FILES_HOME=true`): the app root's own composition (`filesHomeOverrides` for
the platform over an in-process HOM-17 fixture library), with only the platform leaves faked
(engines, saved-signature store, the PDF view):

- flag off: no S4 override from `documentsOverrides` / `pdfToolsOverrides` on any platform,
  `filesHomeOverrides` off, Settings unchanged; every handler, engine, store and environment null,
  the selection bar only the media group, no tools scope around a viewer;
- flag on, six capability sets (iOS, macOS, Android now, Android + HOM-29A/30A, Windows, Linux): the
  real composition has the engine, compress engine and the signature store (at
  `<support>/signatures`) exactly on iOS, macOS and Android; then, per set, the Settings rows, the
  four handlers, the selection bar's Merge into PDF (a PDF and a photo), the PDF file menu
  (Organise pages, Merge with…, Compress…, Sign…), and the opened viewer (Organise pages, Annotate,
  Sign in the top bar; Merge with…, Compress… in the menu; no PDF viewer and the file card on
  Windows and Linux) follow the reported tools. With the selection-bar fix reverted, the four
  iOS/macOS/Android cases fail.

`test/v12/legal/s4_pdf_tools_text_test.dart` (7 tests, green plain and with the flag): content of
every block, no host, the S3 sentence, the blocks are in the policy and the terms exactly when the
build has the flag in the expected sections, the Android rules exclude `signatures` in all three
places, PdfBox-Android's entry has Apache-2.0, the NOTICE and the tools, and the signature fonts are
bundled OFL content fonts.

XCTests: `Tests/Viewer/run_xctests.sh macos` (all core and glue tests incl. the 6 ownership tests),
`ios-typecheck`, `ios-sim` on the **iPhone 17** simulator (booted for the run and shut down after),
`Tests/Compress/run_compress_xctests.sh macos` and `ios` on the same simulator (10 tests): macOS 79,
iOS Simulator 58 and compress 10 + 10, all green. (A first `ios-sim` run under load missed
`testFirstPageOf200PageFileWithin500ms`'s 500 ms budget, 887 ms, and one lost the test runner;
the re-run on a fully booted simulator passed every test.)

Also run green: `test/v12/wiring/` (S1 plain only, as before; S2, S3, S4 tickets' tests plain and with
the flag), `test/v12/legal/`, `test/editor_entry/legal_texts_test.dart`,
`test/editor_entry/licenses_screen_test.dart`, `test/privacy_policy_host_test.dart`,
`test/architecture/dependency_rules_test.dart`, `test/v12/file_actions`, `test/v12/selection`,
`test/v12/library_storage`, `packages/danaview_editor_core/test/store/gc/backup_rules_test.dart`,
`scripts/ci/v12/home_preservation.sh`; `flutter analyze` clean.

### Defects and open items

| # | Item | Owner | Status |
|---|---|---|---|
| D-S4W-1 | The multi-select bar never offered "Merge into PDF" (the app used `fileSelectionGroup`, HOM-28 wired only the handler) | S4-W | fixed in S4-W |
| D-S4W-2 | `danaview_pdf` had no privacy manifest although the S4 tools use required-reason APIs (would block an App Store upload, as FIX-S2R-1 did) | S4-W | fixed in S4-W; verify the bundle in the S4-R `Runner.app` |
| D-S4W-3 | The PDF tools on iOS / macOS could delete a file that appeared at an output path (Windows lane report) | S4-W | fixed in S4-W (XCTests) |
| D-S4W-4 | Android annotate / sign: the viewer's Annotate and Sign, "Sign…" and the Settings rows appear on Android only once HOM-29A / HOM-30A report the tools; the wiring is ready and tested with that capability set | HOM-29A, HOM-30A (Windows) | open (by design) |
| D-S4W-5 | HOM-30A's contract asked for the `signatures` backup exclusion; S4-W added it to both rule files, so HOM-30A must not add it again | HOM-30A | done here; note to Windows |
| D-S4W-6 | `macos/Podfile.lock` checksums of `danaview_pdf` and `danaview_library_native` are stale (both predate their podspec changes); the next macOS `pod install` refreshes them | macOS build owner | open, low |
| D-S4W-7 | The licences screen lists the signature fonts as "(video editor content font)"; they are now also used by Sign. Correct but could name both uses | UX-30 / INT-106 | open, low |
| D-6 (S2) | The features barrel still exports none of the Files & Media Home surfaces; the wiring files use `implementation_imports` | INT-101 (barrel) | open, low |
| — | `legalEffectiveDate`, the owner's review of the S4 wording, the App Store review note, regenerating the hosted privacy page from a build with the flag | S4-R with the owner | open |
| — | For S4-Q: drive every surface of the table above on the iOS Simulator (flag on and off) and on the Android Emulator (HOM-28A/31A surfaces now; annotate and sign after 29A/30A), the multi-select Merge into PDF end to end, Settings › Privacy rows with real saved signatures, a backup check that `signatures/` is excluded (iOS flag, `bmgr` on Android) | S4-Q | open |
