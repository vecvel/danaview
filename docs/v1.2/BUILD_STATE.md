# Danaview 1.2.0 build state

Delivery by release slice (BUILD_PLAN §1A). Branch `v1.2-wip`; Android lane `origin/v1.2-android`.
Last update: 2026-10-22 (S2 Mac half complete).

| Slice | State | Notes |
|---|---|---|
| **S1** Foundations + speed test | **Done on both platforms** (owner items open) | Mac: AIS-01, INT-101, HOM-01, HOM-16, ST-01…ST-05, S1-W, S1-Q Mac half, S1-R iOS candidate. **Android (Windows, 968a10e):** S1-Q Android half green (v1.1 suite 17/18 + 4/4 extras with every 1.2 flag off; s13 only on emulator mic silence, accepted), S1-R Android candidate 1.0.0 (1) AAB 95.4 MB passes check_native_libs.sh, release APK smoke green. Device observations to confirm: OBS-S1A-1 (release player barely advanced the 1080p fixture on the emulator), OBS-S1A-2 (VIEW intent to the running app stays on Home). Windows-host test portability FIX-S1Q-A1…A5 being fixed on the Mac. Owner items: legal date, Q-S1 wording, M-Lab store answers, signing, upload (at the 1.0.0 release). Report: `qa/S1-QA.md` |
| **S2** Photos & Files Home | **Mac half complete; Android half pending (Windows)** | HOM-02, HOM-03, HOM-04, HOM-05…HOM-13, HOM-15, HOM-17…HOM-20, HOM-22, S2-W done. S2-Q Mac half green (S2 E2E on iPhone 16, full v1.1 suite 20/20 with flags off and with `DANAVIEW_FILES_HOME=true`, HOM-15 preservation 406/406 both ways). S2-R Mac half: iOS release build at 1.0.0+1 with S1+S2 flags, min-OS and NEWLAPACK checks OK, 25.1 MB zipped (+0.84 MB vs S1), simulator smoke 10/10; FIX-S2R-1 (privacy manifest) fixed. D-7 fixed (bundled SQLite, sqlite3_flutter_libs 0.5.42). Open: D-3 (Android manifest/backup rules), HOM-02A/04A/20A/22A, S2-Q/S2-R Android halves (Windows); FIX-S1R-1 (fastlane dart-defines) for AIS-41; D-4 Home placement of Import/search (owner/HOM-05), N-R2 thumbnail in Recently deleted (low). Report: `qa/S2-QA.md` |
| S3–S9 | **On hold** (owner 2026-10-22) until v1.1 is certified and S1+S2 are finished on Android | |

## Spikes

| Spike | Result | Open |
|---|---|---|
| AIS-42 Genkit | **No-go**: `danaview_ai_genkit` not created; providers stay on the own adapters (`ai-studio/spikes/AIS-42-genkit.md`) | ARCH V2-203 to record the no-go |
| AIS-44 diarization (Mac half) | Models go (TitaNet-small + pyannote 3.0 int8, RTF 0.094, overlaps kept); **iOS size no-go** with stock sherpa-onnx (+26 MB) (`ai-studio/spikes/AIS-44-diarization.md`) | Owner: Core ML conversion spike (needs coremltools) vs slim build vs +26 MB; TitaNet licence; model hosting; real-speech eval clips. Android half: Windows |
| HOM-27, VED-33A | Windows lane | |
| VED-33 | Waits for VED-33A | |

## Open follow-ups
- FIX-S1R-1 (INT-05 / release integration, AIS-41): `ios/fastlane/Fastfile` `flutter_ipa` and `android/fastlane/Fastfile` `flutter_aab` pass no release dart-defines (`DANAVIEW_EDITOR`, `DANAVIEW_AUTO_CAPTIONS`, the slice's 1.2.0 flags) and default the build number to 1 / a timestamp / next TestFlight instead of the pubspec; blocks signing through any lane (manual commands in `qa/S1-QA.md` §Signing). S1 candidate commit: `f865874` signed at `1.0.0+1`.
- `legalEffectiveDate` to the S1 candidate's date, owner review of the privacy wording (Q-S1) and the store answers for M-Lab: at S1-R.
- No CI path filter runs `packages/danaview_data` tests (low; review finding).
- `cue_list_performance_test` (8 ms budget) is flaky under `-j 2` on the 8 GB Mac; passes alone.
- Owner questions Q-A1…Q-A10 (ARCH v1.2 §16) still open; recommendations used as working defaults.
