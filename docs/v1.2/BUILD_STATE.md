# Danaview 1.2.0 build state

Delivery by release slice (BUILD_PLAN §1A). Branch `v1.2-wip`; Android lane `origin/v1.2-android`.
Last update: 2026-10-22.

| Slice | State | Notes |
|---|---|---|
| **S1** Foundations + speed test | **Built; gate W done, Q Mac half green, R pending** | AIS-01, HOM-01, HOM-16, ST-01…ST-05, S1-W done. INT-101 partial: `BeautyInspector` can't join the sealed `InspectorRoute` without editing UX-16's exhaustive switches; moved to VED-26 (S9) as an [INTEGRATION] amendment. Review findings fixed: rule 28 false positive (FIX-S1Q-1), checks for rules 16/18/19 (FIX-S1Q-2), the VED action ids behind their flags. S1-Q: full v1.1 iOS suite 20/20 in both batches (flags off; S1 flag set); Android half pending Windows. Report: `qa/S1-QA.md` |
| S2 Photos & Files Home | Next | Mac tickets building; `A` tickets on Windows |
| S3–S9 | Not started | |

## Spikes

| Spike | Result | Open |
|---|---|---|
| AIS-42 Genkit | **No-go**: `danaview_ai_genkit` not created; providers stay on the own adapters (`ai-studio/spikes/AIS-42-genkit.md`) | ARCH V2-203 to record the no-go |
| AIS-44 diarization (Mac half) | Models go (TitaNet-small + pyannote 3.0 int8, RTF 0.094, overlaps kept); **iOS size no-go** with stock sherpa-onnx (+26 MB) (`ai-studio/spikes/AIS-44-diarization.md`) | Owner: Core ML conversion spike (needs coremltools) vs slim build vs +26 MB; TitaNet licence; model hosting; real-speech eval clips. Android half: Windows |
| HOM-27, VED-33A | Windows lane | |
| VED-33 | Waits for VED-33A | |

## Open follow-ups
- `legalEffectiveDate` to the S1 candidate's date, owner review of the privacy wording (Q-S1) and the store answers for M-Lab: at S1-R.
- No CI path filter runs `packages/danaview_data` tests (low; review finding).
- `cue_list_performance_test` (8 ms budget) is flaky under `-j 2` on the 8 GB Mac; passes alone.
- Owner questions Q-A1…Q-A10 (ARCH v1.2 §16) still open; recommendations used as working defaults.
