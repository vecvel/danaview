# Diarization eval set (AIS-44 → AIS-48)

Owned by AIS-44. Used by AIS-46/AIS-48 to gate "overlapping speech gives separate per-speaker cues". Report: `docs/v1.2/ai-studio/spikes/AIS-44-diarization.md`.

## Scoring

`spikes/ais-44-diarization/tool/score.py` scores each clip:
- DER on 10 ms frames, with overlap scored and an optimal speaker mapping, at no collar and at a 0.25 s collar
- speaker count found against the reference
- overlap recall, overlap precision, and "both speakers right" in overlap frames

The reference for each clip is RTTM plus JSON (speaker, start, end in seconds).

## Set A: synthetic (in place, model comparison only)

The clips are generated on macOS by `spikes/ais-44-diarization/tool/make_clips.py` (`say` voices, 16 kHz mono). They carry no licence restrictions because they are generated locally. The four clips under 1 MB are tracked; regenerate the others.

| Clip | Length | Speakers | Overlap | What it tests |
|---|---|---|---|---|
| c1_2spk_turns | 31.1 s | Samantha, Daniel | 0 s | clean turns, different voices |
| c2_2spk_overlap | 24.8 s | Samantha, Daniel | 4.7 s | three 1.2–2.0 s overlaps |
| c3_3spk_turns | 34.3 s | Samantha, Daniel, Karen | 0 s | three speakers |
| c4_3spk_overlap | 27.3 s | Samantha, Daniel, Karen | 4.8 s | three speakers with cut-ins |
| c5_2spk_similar | 27.7 s | Samantha, Karen | 1.0 s | two similar voices (the hard case) |
| c6_2spk_male | 32.5 s | Daniel, Ralph | 0.8 s | two male voices |
| l1_4spk_long | 553.7 s | all four | 23.2 s | speed, memory, count estimation |

## Set B: real speech (pending owner decision 5 in the AIS-44 report)

This set is required before the AIS-48 gate. Proposed contents:

| # | Content | Length | Must include |
|---|---|---|---|
| B1 | 2 people talking, phone on a table | 3–5 min | at least 5 overlaps (interruptions, "mm-hm") |
| B2 | 3 people, two of the same gender and age | 5 min | similar voices and cross-talk |
| B3 | 4 people, a noisy room (café or kitchen) | 10 min | background noise and long turns |
| B4 | 1 person (a false-split check) | 2 min | a single speaker with pauses |
| B5 | an interview video with music under it | 3 min | music bed |

Source for each clip: owner-recorded with written consent from everyone on it, or a CC-BY/CC0 clip with its URL, licence and attribution recorded here. Ground truth is labelled by hand in RTTM, and overlaps are marked explicitly.
