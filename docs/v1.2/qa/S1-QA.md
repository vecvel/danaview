# S1 · Foundations + speed test: gate report

Slice S1 of 1.2.0 (BUILD_PLAN v1.2 §1A). The gate has three tickets: S1-W (wiring and legal,
§Wiring below), S1-Q (slice QA, the remaining sections of this report) and S1-R (release
candidate). S1-Q adds its sections below §Wiring; S1-W edits only §Wiring.

## Wiring

Ticket **S1-W**, Mac lane, on `v1.2-wip`, 2026-10-22. No feature work; integration rights limited to
the S1 features (ST-01…ST-05; AIS-01, INT-101, HOM-01, HOM-16 have no user-visible surface).

### What is wired

| S1 feature | Where it is reached in the app | Status |
|---|---|---|
| Speed-test fallback (ST-01…ST-03) | Settings › Speed test (`/settings/speed-test`, the 1.0 route, unchanged). `speedTestServiceProvider` defaults to ST-04's `FallbackSpeedTestService` over the ST-03 coordinator; `main.dart` does not override it | already wired by ST-04; verified |
| One-time consent prompt (ST-04) | Shown by the speed-test screen when the default servers fail a phase and the answer is "never asked"; "Not now" or a revoked answer means default servers only | already wired by ST-04; verified |
| Settings › Privacy toggle (ST-04) | **Added by S1-W:** `lib/router/app_router.dart` hands `appSettingsSections` (`SettingsSections(privacy: buildPrivacySettingsSection)`) to `DanaviewSettingsScreen`, so the section shows after the Tools group (INT-101 slot). Library storage (HOM-17, S2) and the search index (INT-103, S7) slots stay null | done |
| Privacy text (ST-05) | Settings › About › Privacy Policy and Settings › Privacy Policy: "When Danaview uses the internet" names Cloudflare (default) and M-Lab (only if you agree; results incl. the IP published); "What Danaview doesn't do" and "Your choices" updated | already in place (ST-05); nothing missing |
| Store-answer deltas (ST-05) | `docs/v1.2/speed-test/store_answers.md`: App Privacy (readings A/B for the owner), Data safety, explanation text, App Review note | already in place (ST-05); nothing missing |

### Flag set of the S1 build

- S1 adds **no new flag**: the fallback is consent-gated (§1A table "none new").
- `DANAVIEW_FILES_HOME`, `DANAVIEW_PHOTO_EDITOR`, `DANAVIEW_BEAUTY`, `DANAVIEW_AI_STUDIO` default to
  false and are never flipped in code; the S1-R release build passes **none** of them.
- The v1.1 release defines (`DANAVIEW_EDITOR`, `DANAVIEW_AUTO_CAPTIONS`, per the v1.1 release
  checklist §3.2/§3.3) are unchanged by S1.
- The app reads no other compile-time flag (scan in the wiring test).

With these defaults the app is the 1.1 app plus the speed-test fallback and the Settings › Privacy
section; INT-101's `test/v12/int101/flags_off_test.dart` pins the 1.1 Home, no photo-editor entry
and no beauty tab.

### Licences and terms

- No new licence entry: the NDT7 client is in-house (`dart:io` WebSocket, no third-party package,
  ST-02).
- Terms of Use: no change needed for S1 (speed-test results are already "approximate" under No
  warranty; the Privacy section points to the policy).

### Tests (S1-W)

`test/v12/wiring/s1_wiring_test.dart` (12 tests, green), booting `DanaviewApp` with the real
router:

- every 1.2.0 flag false; the compile-time flags read in `lib/` and `packages/*/lib` are only the six
  known ones, each defaulting to false;
- the app's Settings sections are exactly `privacy`;
- the default speed-test service is the fallback coordinator;
- journey: Settings shows Privacy after Tools (toggle off, "You'll be asked" note) → Speed test →
  Start (default servers busy) → prompt, nothing sent to the open network before the answer → Run on
  open network → back in Settings the toggle is on → turning it off stores `declined` → the next run
  never asks and never uses the open network;
- default servers healthy: no prompt and nothing stored (as in 1.1);
- Settings with the new section: no overflow at 280, 375, 1280 px × text scale 0.85, 1.35; the toggle
  is reachable and at least 44 px tall.

Also run green: `test/v12/` (int101, legal, speed_test, wiring), `test/widget_test.dart`,
`test/settings_account_test.dart`, `test/editor_routes_test.dart`, `test/editor_wiring_test.dart`,
`test/privacy_policy_host_test.dart`, `test/network_tools_test.dart`, `test/home_screen_test.dart`
(243 tests). `flutter analyze --fatal-infos lib test/v12`: no issues.

### Open items

| Item | Owner | Status |
|---|---|---|
| `test/architecture/dependency_rules_test.dart` rule 28 fails on the tree: its regex matches the declaration `factory OpenNetworkConsent.accepted(` in `packages/danaview_data/lib/src/network/speed/mlab_ndt7_provider.dart:38`, not only call sites | INT-101 / ST-04 (architecture test) | defect, blocks the S1 exit criterion "architecture tests green" |
| `legalEffectiveDate` is still `11 October 2026` although the privacy policy changed in S1; set it to the S1 candidate's release date | S1-R (with the owner) | open |
| Owner review of the policy wording (Q-S1) and the App Privacy / Data safety choice for M-Lab | owner, S1-R | open |
| Regenerate the hosted privacy page from `privacyPolicyText` | S1-R | at release |
| Install-and-smoke of the toggle and prompt on a simulator / device | S1-Q / S1-R | deferred: no device available (S1-W ran widget tests only) |

## Slice QA

Ticket **S1-Q**, Mac half, on `v1.2-wip`, 2026-10-22 (tree at `b111fcc`, plus the backup commits
`706d8ba` / later that only touched `ios/Podfile.lock` from the E2E script's `pod install`). QA
changed no product code; every defect below is a FIX ticket that blocks the gate. The Android
Emulator half runs on the Windows laptop.

**Gate verdict (Mac half): red** until FIX-S1Q-1 and FIX-S1Q-2 land. The full v1.1 suite (both
batches), the S1 packages (except rule 28) and the speed-test QA are green.

### 1. S1 packages

Each package analyzed with `--fatal-infos` and tested through its CI script.

| Package / suite | Command | Analyze | Tests |
|---|---|---|---|
| `danaview_ai_providers`, `danaview_ai_studio` (AIS-01) | `scripts/ci/editor/ai.sh` | clean | 4 + 5 pass |
| `danaview_library` (HOM-01, HOM-16, INT-101), `danaview_search`, core photo/colour/beauty | `scripts/ci/v12/library.sh` | clean | 121 + 4 + 14 pass |
| `danaview_library_native`, `danaview_pdf`, `danaview_documents`, `danaview_features` analyze | `scripts/ci/v12/documents.sh` (first part) | clean | 5 + 5 + 4 pass |
| `danaview_face_tracking` | `scripts/ci/v12/face.sh` | clean | 5 pass |
| `danaview_data` speed test (ST-01…ST-03) | `flutter analyze --fatal-infos && flutter test test/network` | clean | 99 pass |
| Root `test/architecture` + `test/v12` (INT-101, ST-04, ST-05, S1-W) | `scripts/ci/v12/documents.sh` (last part) | — | 165 pass, 1 skip (rule 11: `danaview_secure_keys` not created yet), **1 fail (rule 28, FIX-S1Q-1)** |
| Editor architecture (rule 13/17 consent sites, AIS-01) | `cd packages/danaview_editor && flutter test test/architecture` | — | 44 pass |
| v1.1 root suites the speed test and settings touch | `flutter test test/network_tools_test.dart test/privacy_policy_host_test.dart test/widget_test.dart test/settings_account_test.dart test/home_screen_test.dart test/editor_routes_test.dart test/editor_wiring_test.dart` | — | 165 pass |
| Root analyze | `flutter analyze --fatal-infos lib test/v12 test/architecture` | clean | — |

`danaview_features` has no `test/` directory of its own (its 1.2.0 tests live in root `test/v12/`).

### 2. Architecture rules 9–31: planted violations

Beyond the fixtures (all 50, negative ones and positive controls, fire exactly their expected rules), each rule was checked against the
**real tree**: a copy of the repository sources (in the scratch directory, never in the repo) got one
planted violation at a time, and the root architecture checks (`checkAll` of
`test/architecture/dependency_rules_test.dart`) and the rule 13/17 scan
(`aiConsentViolations` of `packages/danaview_editor/test/architecture/ai_call_sites_test.dart`) were
run on it. The unmodified copy reports only the rule 28 false positive (FIX-S1Q-1), which is
subtracted from each result.

| Rule | Planted violation | Fired |
|---|---|---|
| 9 | `danaview_ai_providers` lib imports `package:flutter/foundation.dart` | 9 |
| 10 | `danaview_ai_studio` lib imports `danaview_editor` | 10 |
| 11 | a `danaview_secure_keys` package depending on and importing `danaview_domain` | 11 |
| 12 | `danaview_editor` lib imports `danaview_face_tracking` | 12 |
| 13 | *(replaced by 17)* | — |
| 14 | `HttpClient()` in `danaview_ai_studio` lib | 14 |
| 15 | `print(body)` in `danaview_ai_providers`; a `?key=` URL | 15, 15 |
| 16 | a `danaview_ai` package depending on `http` and `danaview_editor_core` | **nothing** (FIX-S1Q-2) |
| 17 | `AiSendConsent.accepted(` / `ProviderProbeConsent.accepted` in AI Studio, the app root and the editor | 2 violations each (reported under id `13`) |
| 18 | `HttpClient()` in `danaview_search` lib | **nothing** (FIX-S1Q-2) |
| 19 | `import 'package:genkit/genkit.dart'` in `danaview_ai_studio` | only rule 10 (no rule 19 check; FIX-S1Q-2) |
| 20 | `dart:io` in `danaview_library/lib/src/model/`; Flutter import there | 20, 20 |
| 21 | `WebSocket.connect` in `danaview_pdf` Dart; `URLSession` in `danaview_library_native` Swift | 21, 21 |
| 22 | `danaview_documents` imports `danaview_search` | 22 |
| 23 | `danaview_features` imports `danaview_pdf`; imports `danaview_ai_studio` | 23, 23 |
| 24 | `danaview_search` imports Flutter | 24 |
| 25 | `dart:io` in `danaview_editor_core/lib/src/photo/` | 2, 25 (rule 2 overlap, expected) |
| 26 | `deleteSync` in `danaview_library/lib/src/actions/`; App Group id in `danaview_pdf` Swift | 26, 26 |
| 27 | `FileHandle(forUpdating:)` in `danaview_pdf` Swift | 27 |
| 28 | `OpenNetworkConsent.accepted(` in `danaview_features/lib/src/` and in the app `lib/` | 28, 28 |
| 29 | `danaview_editor` imports `danaview_library` | 29 |
| 30 | `print(name)` in `danaview_library`; an interpolated `print` in `settings_sections/` | 30, 30 |
| 31 | `Switch` in `settings_sections/`; `AlertDialog` appended to the ST-04 `network_format.dart` | 31, 31 |
| F | `bool.fromEnvironment('DANAVIEW_FILES_HOME')` outside the flags file | F |

Result: rules 9–12, 14, 15, 17 and 20–31 (and F) catch a planted violation on the real tree.
**Rules 16, 18 and 19 have no check yet** (the test header assigns them to AIS-43, slice S6). S1's
exit criterion asks for every rule 9–31, so this is filed as FIX-S1Q-2. Rule 18 matters now:
`danaview_search` already exists and can open a socket without any test failing.

### 3. Speed-test QA (fakes, no network)

The ST-03 coordinator tests (`packages/danaview_data/test/network/speed/coordinator_test.dart`), the
ST-04 widget tests (`test/v12/speed_test/speed_consent_test.dart`) and the S1-W journey
(`test/v12/wiring/s1_wiring_test.dart`) are green (counted in §1). QA also ran its own scratch
widget test (not committed), with the ST-04 fake providers behind the real ST-03 coordinator and
the real `DanaviewSpeedTestScreen`: 8 of 8 pass.

| Check | Result |
|---|---|
| **Failover only after consent.** Never asked, default servers rate-limiting at latency, at download, at upload: the prompt shows, the open network has run **no** phase and no ticket exists before the answer; after "Run on open network" the ticket exists and the open network runs only the failed phase and later ones (phases never mix) | pass (3 phases) |
| **Toggle off = default servers only.** Answer stored as `declined` (what turning the Settings › Privacy toggle off writes, see the ST-04 test), default servers failing at each phase, three runs each: never a prompt, the open network never called, no ticket, the answer stays `declined` | pass (3 phases × 3 runs) |
| "Not now" at 280 px × 0.85: calm failure "Couldn't reach a test server", no open-network call, remembered as `declined` | pass |
| Default servers healthy at 320 px × 1.35: no prompt, no open network, no notes, nothing stored (1.1 behaviour) | pass |
| **Neutral copy.** Every shown string and semantics label in the idle, prompt, result, healthy-result and calm-failure states scanned for `cloudflare`, `m-lab`, `measurement lab`, `measurementlab`, `ndt`, `locate.`: none. The result names only "Tested against a nearby server" and the details-row notes ("Open network: measured over a single connection", "measured on two servers"); the provider attribution of ST-03 stays internal | pass |
| Hosts: `speed.cloudflare.com` (as in 1.1) and `locate.measurementlab.net` + the NDT7 server it returns, only behind the ticket; named in the privacy policy (ST-05 test); the M-Lab provider refuses without a ticket and the no-network guard blocks real M-Lab hosts in tests (ST-02 `mlab_test.dart`) | pass |

### 4. Network guard, persistence, overflow and accessibility (S1 scope)

- **Network guard (QA-103 scope):** S1 adds one network destination, M-Lab, reachable only with an
  `OpenNetworkConsent` ticket (rule 28 planted check in §2, ST-02 refusal test). No AI package or
  1.2.0 plugin opens a socket (rules 14, 21 planted checks). Device network spy: deferred: no device
  available.
- **Persistence (QA-106 scope):** S1 stores two prefs values, the consent answer
  (`PrefsSpeedConsentStore`, round trip and unreadable values → "never asked", ST-04 test) and the
  10-minute provider skip (`ProviderHealthStore`, survives a restart through prefs, clock moved back
  cannot extend it, mistyped value → no skip, ST-03 tests). Backup/restore survival on a device:
  deferred: no device available.
- **Overflow and accessibility (QA-105 scope):** the prompt, notes, calm failure and Settings ›
  Privacy fit at 280–1280 px × text scale 0.85–1.35, prompt buttons ≥ 44 px and labelled, contrast
  computed on the dark UI (ST-04 matrix); Settings with the new section fits at 280/375/1280 px ×
  0.85/1.35 with a ≥ 44 px toggle (S1-W). All green.

### 5. Full v1.1 suite on the iOS Simulator

`scripts/ci/editor/e2e_ios.sh iphone` with `DV_E2E_IPHONE="iPhone 16"`,
`DV_E2E_IPHONE_RUNTIME="iOS 26.5"`, models staged in place from `/Users/besaoct/danaview-models`
(nothing downloaded). The script passes the v1.1 release defines `DANAVIEW_EDITOR=true` and
`DANAVIEW_AUTO_CAPTIONS=true`. S1 adds no flag (§1A: "none new"), so the S1 build's flag set is
"every 1.2.0 flag false"; batch 2 passes that set explicitly so the build is the S1-R one.

| Batch | 1.2.0 defines | Started / ended | Result |
|---|---|---|---|
| 1 · every 1.2.0 flag off | none (defaults, all false) | 03:04 / 03:31 | **20 of 20 files pass** (s01–s18, `x_android_api28`, `x_ios_background_export`; `x_android_export_background` skipped on iOS as designed), no harness retry |
| 2 · S1 flag set (the S1-R build) | `DANAVIEW_FILES_HOME=false DANAVIEW_PHOTO_EDITOR=false DANAVIEW_BEAUTY=false DANAVIEW_AI_STUDIO=false` (via `DV_E2E_EXTRA_DEFINES`, confirmed on the `flutter test` command lines) | 03:32 / 03:59 | **20 of 20 files pass**, no harness retry (s13 start latency 133 ms, simulator reality) |

Simulator realities reported, not failed (batch 1, same as QA-01 re-run 4): HEVC/MOV not offered
(`hevcEncode false`); `pausedInBackground observed: false`; s13 start latency 200 ms (simulator
budget 750 ms, device budget 100 ms). Evidence: s07 burned cues 341 and 324 changed samples (needs
> 180); s08 3 cues from the tiny model; s12 marquee and wheel zoom as QA-01; s15 head -14.6 dBFS,
body -9.0 dBFS. Logs: `build/e2e/ios/6663101E-6BE7-47D4-B3B8-055700BF2E02/` (summary.txt,
logs/host.log). The simulator was booted by the script and shut down after each batch.

The iPad (s12), iOS 18.2 legacy and lab lanes were not part of this gate's scope (the gate asks for
the full v1.1 suite on the iPhone 16 lane); the lab lane is deferred: no device available.

### 6. Android Emulator half

pending: Windows

### 7. Defects (FIX tickets, block the gate)

| Id | Owner | Defect | Evidence | Fix direction |
|---|---|---|---|---|
| **FIX-S1Q-1** | INT-101 (`test/architecture/dependency_rules_test.dart`, rule 28) | Rule 28 fails on the clean tree: the regex `OpenNetworkConsent\s*\.\s*accepted\b` also matches the **declaration** `factory OpenNetworkConsent.accepted(DateTime at)` in `packages/danaview_data/lib/src/network/speed/mlab_ndt7_provider.dart:38`, so `test/architecture` and `scripts/ci/v12/documents.sh` are red | `rule 28: packages/danaview_data/lib/src/network/speed/mlab_ndt7_provider.dart:38: creates an OpenNetworkConsent …` | Exempt the declaring file (as rule 17's `ai_call_sites_test.dart` exempts each consent's `declaration`) or skip `factory` declarations; keep the planted call-site checks of §2 firing |
| **FIX-S1Q-2** | INT-101 with AIS-43 (architecture tests) | Rules 16, 18 and 19 of ARCH v1.2 §4.2 have no check: a planted `danaview_ai` with foreign dependencies, `HttpClient()` in `danaview_search`, and a Genkit import fire nothing as their rules (19 is caught only incidentally by rule 10). The S1 exit criterion is "a planted violation of every rule 9–31" | §2 rows 16, 18, 19 | Add at least rule 18's socket grep for `danaview_search` now (it exists), plus rules 16 and 19 with negative fixtures that run once `danaview_ai` / `danaview_ai_genkit` exist (skip notice until then, like rule 11), or have the owner move them out of S1's exit criterion in writing |

Not defects, carried from §Wiring for S1-R: `legalEffectiveDate`, the owner's Q-S1 wording review,
the hosted privacy page, and the install-and-smoke of the prompt and toggle on the simulator
(S1-R's install-and-smoke step).

## Release candidate

Ticket **S1-R**, Mac half, on `v1.2-wip`, 2026-10-22. Build tree: `4499909` plus the working tree of
04:20 (the version bump below and other builders' S2 work in progress behind `DANAVIEW_FILES_HOME`,
off; captured by backup `f865874`). Nothing was signed, uploaded or changed in the signing settings.

### Version

| File | Before | After |
|---|---|---|
| `pubspec.yaml` | `1.0.0+1` | **`1.2.0+4`** |
| `packages/danaview_features/lib/src/more/app_info.dart` (must match, `settings_account_test`) | `1.0.0` / `1` | `1.2.0` / `4` |
| `test/settings_account_test.dart` | literals `Danaview 1.0.0 (1)`, `Version 1.0.0 (build 1)` | read from `danaviewAppVersion` / `danaviewBuildNumber` (no literal to bump next time) |

Build 4 is above build 3, which the 1.1.0 checklist (`docs/v1.1/editor/release-checklist.md` §3.1)
reserves for 1.1.0 and never applied (1.0.0 was build 1). If App Store Connect or Play already holds
a build ≥ 4, the owner uses the next free number on both stores; the iOS `beta` lane takes the next
TestFlight number by itself, `release` needs `BUILD_NUMBER=4`.

### iOS release build

```text
flutter build ipa --release --no-codesign --build-number=4 \
  --dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true \
  --dart-define=DANAVIEW_FILES_HOME=false --dart-define=DANAVIEW_PHOTO_EDITOR=false \
  --dart-define=DANAVIEW_BEAUTY=false --dart-define=DANAVIEW_AI_STUDIO=false
```

The v1.1 release defines (editor, Auto captions) as in the 1.1 checklist §3.2; every 1.2.0 flag
false (S1 adds none). `WhisperCore.xcframework` was present (vendored build, nothing downloaded).

| Check | Result |
|---|---|
| Build | **pass**, 2 min (warm cache): `build/ios/archive/Runner.xcarchive` (247.6 MB with dSYMs); `--no-codesign` skips the IPA export |
| Info.plist | `CFBundleShortVersionString 1.2.0`, `CFBundleVersion 4`, `MinimumOSVersion 15.0`, `com.vecvel.danaview`, display name Danaview |
| `check_ios_min_os.sh --min 15.0` on the archived `Runner.app` | **OK**: 28 binaries, 1414 symbols probed, weak allowlist BackgroundTasks |
| `nm -um` `NEWLAPACK` on `Runner.app/Frameworks/*` | none |
| Flutter warning | launch image is the default placeholder (same as 1.1; owner asset, not a blocker) |

**Size** (unsigned, measured on the archive's `Runner.app`):

| Measure | S1 candidate 1.2.0+4 |
|---|---|
| `Runner.app` on disk | 61.5 MB (62 956 KB) |
| `Payload/Runner.app` zipped (`zip -9`, an unsigned stand-in for the IPA) | 24.2 MB (24 237 779 B) |
| Largest frameworks | App 21.8 MB, Flutter 9.8 MB, Harfbuzz 6.4 MB, danaview_editor_engine 5.0 MB, danaview_whisper 3.5 MB, Avcodec 3.4 MB |

**No 1.1.0 release build is recorded** (the 1.1 checklist leaves "IPA growth" open and compares App
Store Connect file-size reports, which only exist after an upload). The only older IPA on this Mac is a
signed 1.0-era export (`build/ios/ipa/vwish.ipa`, 2026-10-04, 28.8 MB) from before the rename and the
editor; it is not comparable (different export, no editor). The owner records the App Store Connect
"App Store file sizes" for this candidate and for 1.1.0 once both are uploaded; ARCH §10.3 asks AIS-41
for the 1.2.0-vs-1.1.0 delta.

### Install and smoke on the iOS Simulator (iPhone 16, iOS 26.5)

Release and profile builds cannot run on a simulator (`flutter build ios --simulator --release`:
"Release mode is not supported for simulators"; `--profile`: "Profile mode is not supported for
simulators"). The smoke therefore ran a **debug** simulator build of the same tree, version and
defines; the release binary itself is checked statically above and on a device only (see open items).

1. `flutter build ios --simulator --debug --build-number=4` with the defines above, `simctl install`,
   `simctl launch`: the app launches to the **1.1 Home** (Open file / Open folder / Open link,
   Playlists, Folders, editor button left of the gear), no Files Home tabs.
2. A scripted run through the E2E harness (`scripts/ci/editor/e2e_ios.sh --target <scratch smoke>
   iphone`, S1 flag set via `DV_E2E_EXTRA_DEFINES`; the scratch file was deleted afterwards), on the
   real app wiring, **pass** in 2 min:

| Step | Result |
|---|---|
| Launch, Home | pass: 1.1 Home |
| Player | pass: `frame_counter_1080p30.mp4` (local fixture) opens, duration 8 s, playback advances |
| Editor open | pass: player › Edit opens the editor with one clip; closed and saved |
| Settings › Privacy toggle | pass: section shown with the "You'll be asked the first time" note; toggled on (note goes, answer stored) and back off; About shows "Version 1.2.0", footer "Danaview 1.2.0 (4)" |
| Speed test, default servers healthy | pass: no consent prompt, result over the real network (download 59.8 Mbps, upload 65.6 Mbps, ping 25 ms, jitter 18 ms, 87.9 MB in 15 s); result names only "Tested against a nearby server · <city>", no provider name |

The simulator was booted for this step and shut down after it.

Device smoke of the signed release build (iPhone 12 mid tier, iPhone 7 iOS 15.8, iPhone 8 iOS 16.7):
deferred: no device available.

### Android candidate

pending: Windows (`flutter build appbundle --release` with the same defines and `1.2.0+4`,
`check_native_libs.sh`, install and smoke on the API 35 emulator).

### Release checklist (S1)

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | Gate: S1-W done; S1-Q Mac half green once FIX-S1Q-1 and FIX-S1Q-2 have landed (§7); Android half of S1-Q | INT-101 / AIS-43, Windows | open (see BUILD_STATE) |
| 2 | Version `1.2.0+4` in `pubspec.yaml` and `app_info.dart` | S1-R | **done** |
| 3 | iOS release build with the S1 flag set, min-OS check, `NEWLAPACK` check | S1-R | **done** (above) |
| 4 | Simulator install and smoke | S1-R | **done** (debug build, release impossible on simulator) |
| 5 | Device smoke of the signed build | owner / lab | deferred: no device available |
| 6 | Android release build, native-lib check, emulator smoke | Windows lane | pending: Windows |
| 7 | **Signing**: archive with the distribution certificate and profile (`fastlane ios build` / `beta` with the release `.env`), Android upload key | **owner** | open |
| 8 | **Upload** to TestFlight / Play internal testing (candidates stay internal until the owner's go; v1.1 goes live after v1.3) | **owner** | open |
| 9 | **`legalEffectiveDate`** (`legal_texts.dart`, still `11 October 2026`) to the candidate's release date, then regenerate the hosted privacy page from `privacyPolicyText` | **owner** (date), then the release integration ticket | open |
| 10 | **Owner policy review Q-S1**: the Cloudflare and M-Lab wording in "When Danaview uses the internet" (ST-05, V2-406) | **owner** | open |
| 11 | **M-Lab store answers**: App Privacy reading A or B, Data safety shared/exempt (`docs/v1.2/speed-test/store_answers.md` §3–§4, with Q-A9) and the optional App Review note (§5) | **owner** (with legal) | open |
| 12 | IPA/AAB size vs 1.1.0 from the store reports after upload (ARCH §10.3) | owner, AIS-41 | open (S1 numbers above) |
| 13 | Privacy manifest report from the signed archive (Organizer › Generate Privacy Report): unchanged from 1.1 (S1 adds no SDK) | owner | open |
| 14 | Launch image placeholder (Flutter validation warning, as in 1.1) | owner | open, not a blocker |

**S1-R Mac verdict:** the iOS candidate `1.2.0+4` builds in release with only the S1 flags, passes the
15.0 floor and `NEWLAPACK` checks, and smokes green on the iPhone 16 / iOS 26.5 simulator (debug build
of the same tree). Signing, upload, the effective date, Q-S1 and the M-Lab store answers are the
owner's and stay open; the Android candidate is pending on Windows.
