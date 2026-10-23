# Architecture rule fixtures (INT-01)

Fixture trees for `test/architecture/dependency_rules_test.dart`. Each directory mirrors the repo
layout (`packages/<name>/pubspec.yaml`, `packages/<name>/lib/...`) with a `.fixture` suffix on
every file, so neither pub nor the analyzer treats them as real packages or sources. The test runs
every rule (ARCH §4.2 rules 1–7, the 1.2.0 AI rules 9–12, 14 and 15 added by AIS-01, and the
ARCH §1.3 Material rule `M`) against each tree and expects
exactly the rule ids listed in `fixtureExpectations`.

| Fixture | Fires | Proves |
|---|---|---|
| `ok_wrappers_and_barrels` | nothing | kit wrappers (`DanaviewTextField`, `DanaviewIconButton`), forbidden names in comments/strings, `switch`, `dart:io` under `lib/src/store/` and in `test/`, nested `example/` packages and the three allowed `danaview_features` entry points all pass |
| `m_unlisted_file_not_scanned` | nothing | the Material scan covers only the editor-touched file list |
| `r1_features_depends_on_editor` | 1 | `danaview_features` listing an editor package in `dependencies` |
| `r1_features_dev_dependency_and_override` | 1 (×2) | the same in `dev_dependencies` and `dependency_overrides` |
| `r1_features_imports_editor` | 1 | `danaview_features` importing an editor package without declaring it |
| `r2_core_depends_on_flutter` | 2 (×2) | `flutter` dependency and `flutter_test` dev dependency in the core |
| `r2_core_imports_danaview_package` | 2 | the core importing a `danaview_*` package |
| `r2_core_dart_io_outside_store` | 2 (×1) | `dart:io` outside `lib/src/store/` (the store file in the same tree passes) |
| `r2_core_imports_dart_ui_and_third_party` | 2 (×2) | `dart:ui` and a package outside meta/collection/crypto/path/characters |
| `r3_engine_api_extra_dependency` | 3 | an engine API dependency outside flutter/meta/collection/core |
| `r3_engine_api_imports_plugin` | 3 | the engine API importing the plugin |
| `r4_engine_depends_on_editor` | 4 | the plugin depending on `danaview_editor` |
| `r4_engine_imports_transcription` | 4 | the plugin importing `danaview_transcription` |
| `r5_whisper_depends_on_danaview` | 5 | `danaview_whisper` depending on a `danaview_*` package |
| `r5_whisper_imports_danaview` | 5 | `danaview_whisper` importing a `danaview_*` package |
| `r6_transcription_depends_on_engine_api` | 6 | transcription depending on the engine API |
| `r6_transcription_widget_code` | 6 | widget library import plus a widget class in transcription |
| `r6_transcription_widget_class_without_import` | 6 | a widget/`State` class is caught even without a widgets import |
| `r7_editor_depends_on_plugin` | 7 | `danaview_editor` depending on the plugin |
| `r7_editor_imports_features_internals` | 7 | `danaview_editor` importing a `danaview_features/src/` file |
| `r7_editor_imports_features_barrel` | 7 | `danaview_editor` importing the full `danaview_features` barrel (tests included) |
| `m_features_material_chrome` | M (×5) | `Switch`, `Slider`, `TextButton`, `showDialog`, `AlertDialog` in an editor-touched file |
| `m_features_material_in_interpolation` | M | a forbidden name inside `${…}` string interpolation is code |
| `ok_ai_packages_clean` | nothing | 1.2.0 (AIS-01): the planned AI manifests and imports, `HttpClient()` only in `http_transport.dart`, `HttpClient` in comments/strings/types, literal logs, `math.log`/`ledger.log`, and tests (not scanned by 14/15) all pass |
| `r9_providers_depends_on_flutter` | 9 (×3) | `flutter`, a third-party package and a `danaview_*` package in `danaview_ai_providers` |
| `r9_providers_imports_flutter_and_danaview` | 9 (×3) | `package:flutter`, a `danaview_*` package and a third-party package imported by the providers |
| `r10_studio_depends_on_editor_and_keys` | 10 (×3) | `danaview_editor`, `danaview_secure_keys` and an unplanned package in `danaview_ai_studio` |
| `r10_studio_widget_code` | 10 (×2) | a widgets import and a widget class in AI Studio |
| `r11_secure_keys_depends_on_danaview` | 11 (×2) | the key store depending on and importing a `danaview_*` package |
| `r11_features_imports_secure_keys` | 11 (×2) | a package other than the app root depending on and importing the key store |
| `r12_editor_imports_native_plugins` | 12 (×3) | `danaview_editor` depending on the key store and diarization and importing face tracking |
| `r14_http_client_outside_transport` | 14 (×3) | `HttpClient()`, `new HttpClient()` and `HttpClient.new` outside the transport |
| `r15_key_in_url` | 15 (×2) | `?key=` in a provider URL and in a tool comment |
| `r15_logs_content` | 15 (×4) | logging an interpolated body, a response, a caption and a prompt |

Adding a fixture: create the directory, add it to `fixtureExpectations` (and to
`fixtureViolationCounts` when the count matters), and add a row here.
