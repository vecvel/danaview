# Danaview 1.2.0 build state

Delivery by release slice (BUILD_PLAN §1A). Branch `v1.2-wip`; Android lane `origin/v1.2-android`.
Last update: 2026-10-22 (S2 Mac half complete).

| Slice | State | Notes |
|---|---|---|
| **S1** Foundations + speed test | **Done on both platforms** (owner items open) | Mac: AIS-01, INT-101, HOM-01, HOM-16, ST-01…ST-05, S1-W, S1-Q Mac half, S1-R iOS candidate. **Android (Windows, 968a10e):** S1-Q Android half green (v1.1 suite 17/18 + 4/4 extras with every 1.2 flag off; s13 only on emulator mic silence, accepted), S1-R Android candidate 1.0.0 (1) AAB 95.4 MB passes check_native_libs.sh, release APK smoke green. Device observations to confirm: OBS-S1A-1 (release player barely advanced the 1080p fixture on the emulator), OBS-S1A-2 (VIEW intent to the running app stays on Home). Windows-host test portability FIX-S1Q-A1…A5 being fixed on the Mac. Owner items: legal date, Q-S1 wording, M-Lab store answers, signing, upload (at the 1.0.0 release). Report: `qa/S1-QA.md` |
| **S2** Photos & Files Home | **Done on both platforms** (owner items open) | Mac half as before (S2-Q green, S2-R iOS candidate, FIX-S2R-1, D-7). **Android (Windows, `f125f8c`):** D-3, HOM-02A, HOM-04A, HOM-20A, HOM-22A; D-7 verified; S2-Q Android half green (S2 E2E on API 35, full v1.1 suite with the flag 17/18 + 7/7, bmgr backup checks); S2-R Android AAB 101.0 MB (+5.5 MB), native-lib checks pass, release smoke green. Open, low: FIX-S2Q-A1 (E2E expects the platform's primary save target), FIX-S2Q-A2 (e2e_android.sh define pass-through), OBS-S2A-1 (picker names), OBS-S2A-3 (video-only album chips). Report: `qa/S2-QA.md` |
| **S3** Documents: view and share-in | **Done on both platforms** (2026-10-23) | Mac half as recorded (S3-Q green, iOS RC 26.06 MB). **Android (Windows, 90c7a5b7):** HOM-25, HOM-21A (flag-gated alias); S3-Q Android green (S3 E2E with real intents, v1.1 suite with the flag, flag-off check, tablet grids); S3-R Android AAB 108.2 MB (+7.2 MB), native-lib checks pass. FIX-S3Q-A1 (Office MIME by extension) and A2 (PdfBox-Android + Bouncy Castle licences) fixed. Low items carried to S4. Report: `qa/S3-QA.md` |
| S4–S9 | Not started | |

## Spikes

| Spike | Result | Open |
|---|---|---|
| AIS-42 Genkit | **No-go**: `danaview_ai_genkit` not created; providers stay on the own adapters (`ai-studio/spikes/AIS-42-genkit.md`) | ARCH V2-203 to record the no-go |
| AIS-44 diarization (Mac half) | Models go (TitaNet-small + pyannote 3.0 int8, RTF 0.094, overlaps kept); **iOS size no-go** with stock sherpa-onnx (+26 MB) (`ai-studio/spikes/AIS-44-diarization.md`) | Owner: Core ML conversion spike (needs coremltools) vs slim build vs +26 MB; TitaNet licence; model hosting; real-speech eval clips. Android half **GO** (87fef930, report §10): matches the Mac's DER |
| HOM-27 Android PDF write | **Decided**: PdfBox-Android 2.0.27.0 (route b), +2.0 MB, every operation passes on API 28–37 (`files-media-home/spikes/HOM-27-android-pdf-write.md`) | |
| VED-33A face tracking (Android) | **Done** (f256d500, `spikes/face_android/REPORT.md`): MediaPipe Tasks Vision 0.10.35, +5.0 MB arm64, the same library as iOS; LiteRT 2.3.0 fallback; ONNX Runtime no-go on size; synthetic heads for committed landmark dumps (no landmarks of the real Pexels people kept) | VED-33 (iOS half) in S8 |
| VED-33 | Waits for VED-33A | |

## Open follow-ups
- FIX-S1R-1 (INT-05 / release integration, AIS-41): `ios/fastlane/Fastfile` `flutter_ipa` and `android/fastlane/Fastfile` `flutter_aab` pass no release dart-defines (`DANAVIEW_EDITOR`, `DANAVIEW_AUTO_CAPTIONS`, the slice's 1.2.0 flags) and default the build number to 1 / a timestamp / next TestFlight instead of the pubspec; blocks signing through any lane (manual commands in `qa/S1-QA.md` §Signing). S1 candidate commit: `f865874` signed at `1.0.0+1`.
- `legalEffectiveDate` to the S1 candidate's date, owner review of the privacy wording (Q-S1) and the store answers for M-Lab: at S1-R.
- No CI path filter runs `packages/danaview_data` tests (low; review finding).
- `cue_list_performance_test` (8 ms budget) is flaky under `-j 2` on the 8 GB Mac; passes alone.
- Owner questions Q-A1…Q-A10 (ARCH v1.2 §16) still open; recommendations used as working defaults.
