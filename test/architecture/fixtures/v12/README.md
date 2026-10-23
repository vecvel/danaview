# 1.2.0 architecture rule fixtures (INT-101)

Fixture trees for the ARCH v1.2 §4.2 rules 16, 18, 19, 20–31 and the V2-04 flag rule `F` in
`test/architecture/dependency_rules_test.dart`. The format is the one of `../README.md`: each
directory mirrors the repo layout with a `.fixture` suffix on every file (Dart, YAML, Swift and
Kotlin alike), and the test runs every rule against each tree and expects exactly the rule ids in
`v12FixtureExpectations` (and the counts in `v12FixtureViolationCounts`).

| Fixture | Fires | Proves |
|---|---|---|
| `ok_v12_clean` | nothing | the planned manifests of the six new packages; `dart:io` and writes in `store/`, reads in `desktop/` and `actions/`; the Inbox as the App Group reader; `FileHandle(forWritingTo:)` in ExportOut; `openFileDescriptor(…, "r")`; `openOutputStream(uri)` with the default mode; PDF writes in `Tools/`; literal logs; kit components and forbidden names in comments and strings; flags read only in the flags files (and AIS-01's `DANAVIEW_AI_STUDIO` read in `editor_availability.dart`); `OpenNetworkConsent.accepted(` in the consent sheet and its `factory` declaration in danaview_data; v1.0 library files outside the new directories; example apps, URLs in comments and the core photo store's `dart:io` |
| `r16_ai_depends_on_flutter` | 16 (×3) | `flutter` and `danaview_editor_core` dependencies and a `package:flutter` import in `danaview_ai` |
| `r18_search_opens_socket` | 18 (×2) | `HttpClient()` and `WebSocket.connect` in search (the same names in a comment and a string pass) |
| `r19_genkit_outside_genkit_package` | 19 (×3) | `danaview_features` depending on and importing `genkit`, and `package:http` in `danaview_ai_genkit` |
| `r20_library_depends_on_flutter` | 20 (×3) | `flutter` and a `danaview_*` package other than `danaview_domain` in the manifest, and a `package:flutter` import |
| `r20_library_dart_io_outside_allowed` | 20 (×1) | `dart:io` in `lib/src/model/` (the `desktop/` and `inbox/` files in the same tree pass) |
| `r21_plugin_depends_on_danaview_and_sockets` | 21 (×4) | `danaview_pdf` depending on `danaview_library`, and `URLSession` (Swift), `HttpURLConnection` (Kotlin), `Socket.connect` (Dart) in shipped code |
| `r21_face_tracking_downloads_model` | 21 (×1) | a model URL in face tracking code |
| `r22_documents_depends_on_features_and_search` | 22 (×5) | `danaview_features` and `danaview_search` dependencies, a `danaview_editor` dev dependency, and `danaview_ai` / `go_router` imports in documents |
| `r23_features_imports_ai_and_pdf` | 23 (×2) | `danaview_features` depending on `danaview_pdf` and importing `danaview_ai_ui` |
| `r24_search_depends_on_flutter` | 24 (×2) | a `flutter` dependency and a `danaview_documents` import in search |
| `r25_core_photo_imports_io` | 2, 25 | `dart:io` under `lib/src/photo/` (rule 2 fires too; the store file passes both) |
| `r26_library_writes_outside_store` | 26 (×4) | a rename in `lib/src/actions/`, the App Group container outside the Inbox, `openOutputStream(uri, "wt")`, `overwrite: true` in the save-out wrapper |
| `r27_plugin_opens_source_for_writing` | 27 (×4) | `openFileDescriptor(uri, "rw")`, `FileHandle(forUpdating:)`, `RandomAccessFile(path, "rw")`, a PDF `write(to:)` in the viewer |
| `r28_open_network_consent_outside_sheet` | 28 (×2) | `OpenNetworkConsent.accepted(` in the speed-test screen and a tear-off in danaview_data |
| `r29_editor_imports_library` | 29 (×2) | `danaview_editor` depending on `danaview_library` and importing `danaview_documents` |
| `r30_v12_logs_content` | 30 (×4) | logging an interpolated path, a document text, a Swift `\(name)` and a Kotlin `$label` |
| `r31_v12_material_chrome` | 31 (×3) | `Switch` in documents, `Card` in a new Home tab, `Slider` in a photo tool panel |
| `rF_flag_read_outside_flags_file` | F (×2) | `DANAVIEW_FILES_HOME` read in a Home file and `DANAVIEW_BEAUTY` in `editor_availability.dart` |

Adding a fixture: create the directory, add it to `v12FixtureExpectations` (and to
`v12FixtureViolationCounts` when the count matters), and add a row here.
