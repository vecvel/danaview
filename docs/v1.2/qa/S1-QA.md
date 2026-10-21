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
