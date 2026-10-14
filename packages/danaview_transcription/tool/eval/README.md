# Auto captions accuracy eval (QA-06)

Host harness of ai.md §16.5. It runs the apps' whisper shim (CPU) over the clips in
`eval_set.json`, passes the segments through the app's normalizer and segmenter, and reports WER/CER
per tier and language, cue boundary error against human-timed references, the CPS distribution of
the generated cues, the hallucination rate on silence, noise and music, and host speed. Results and
decisions: `docs/v1.1/editor/ai-eval.md`.

## Layout

| Path | What |
|---|---|
| `native/` | `dv_eval_runner`, a small C++ CLI over the shim (CMake; links the shim and vendored whisper.cpp, plus AI-03's fixture-model writer for smoke runs) |
| `src/` | Dart: manifest, synthetic clips, runner invocation and app pipeline, scoring, timing metrics, aggregation, gate, reports |
| `eval_run_test.dart` | The entry point (`flutter test`, because the segmenter uses `dart:ui` types); skipped unless `DV_EVAL_RUNNER` is set |
| `test/` | Unit tests of the harness, the `SpeechTuning` drift guard and an end-to-end smoke test (runs when the runner is built) |
| `eval_set.json` | Clips (pinned) and the plan of the licensed multilingual set |
| `references/` | Reference transcripts (`{"text", "cues": [{"start", "end", "text"}]}`, ms) |
| `baseline.json` | Accepted error rates per tier and language (the regression gate) |

## Running

Use `scripts/ci/editor/nightly.d/ai_eval.sh` (see its header). It builds the runner, fills the
model and clip caches (downloads only in GitHub Actions or with `--download-models`), runs a smoke
eval with the deterministic fixture model, then the accuracy eval on every cached tier.

Environment read by `eval_run_test.dart`: `DV_EVAL_RUNNER` (required), `DV_EVAL_MANIFEST`,
`DV_EVAL_MODELS_DIR`, `DV_EVAL_CLIP_CACHE`, `DV_EVAL_TIERS`, `DV_EVAL_OUT`, `DV_EVAL_SMOKE=1`,
`DV_EVAL_BASELINE`, `DV_EVAL_UPDATE_BASELINE=1`, `DV_EVAL_WRITE_DOC=<ai-eval.md>`,
`DV_EVAL_THREADS`, `DV_EVAL_VAD_THRESHOLD`, `DV_EVAL_NO_SPEECH_THRESHOLD`.

## Adding clips

Every clip has an `id` (`<lang>-<source>-<n>`), a whisper `language`, a `kind` (`speech`,
`silence`, `noise`, `music`), a `source` and a `licence`:

- `remote`: `url` (https), `bytes`, `sha256` of the downloaded file. The nightly script converts it
  to 16 kHz mono s16 WAV with ffmpeg (or afconvert).
- `repo`: `path` relative to this directory and its `sha256`.
- `synthetic`: a `synth` recipe (`silence`, `noise`, `music`; non-speech only).

Allowed licences: `CC0-1.0` (Common Voice), `CC-BY-4.0` (FLEURS; `attribution` required and listed
below), `public-domain` (LibriVox, US government works), `in-house`. Speech clips need a verbatim
reference transcript; add human-timed cues for at least one clip per language.

## Attribution

- `en-repo-jfk`: John F. Kennedy, inaugural address, 20 January 1961 (US government work, public
  domain), as shipped in whisper.cpp `samples/jfk.wav`.
- FLEURS clips (when added): "FLEURS: Few-shot Learning Evaluation of Universal Representations of
  Speech" (Conneau et al., 2022), Google, licensed CC BY 4.0. Each FLEURS clip's manifest entry
  carries this line.
