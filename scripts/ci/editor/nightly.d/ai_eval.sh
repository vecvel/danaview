#!/usr/bin/env bash
# OWNER: QA-06
#
# Nightly Auto captions accuracy eval (ai.md §14.2, §16.5; BUILD_PLAN QA-06). Runs from the
# repository root (scripts/ci/editor/nightly.sh does) or from anywhere.
#
#   1. builds the host eval runner (packages/danaview_transcription/tool/eval/native: the same shim and
#      vendored whisper.cpp as the apps, CPU backend) with CMake (PATH or the Android SDK's);
#   2. model cache: the pinned tiny/base/small q5_1 models and the Silero VAD (ARCH §16.2), size- and
#      sha256-checked, shared with whisper_host.sh. They are downloaded only in GitHub Actions or with
#      --download-models; a local run never downloads anything by default;
#   3. remote eval clips (tool/eval/eval_set.json, source "remote") are fetched into the clip cache with
#      the same rule, checked against their pinned bytes and sha256, and converted to 16 kHz mono
#      s16 WAV (ffmpeg, or afconvert on macOS);
#   4. smoke eval with AI-03's deterministic fixture model (always; proves the chain end to end);
#   5. accuracy eval on every tier whose model is cached, with the regression gate (WER/CER regression
#      <= +1.0 point per tier and language vs tool/eval/baseline.json, median cue boundary error
#      <= 200 ms). Without any cached model the accuracy step is skipped with a notice (locally) and
#      fails in GitHub Actions.
#
# Usage: scripts/ci/editor/nightly.d/ai_eval.sh [--download-models] [--smoke-only] [--build-only]
#                                               [--tiers fast,balanced,accurate] [--write-doc]
#                                               [--update-baseline] [--jobs N]
#   --write-doc        rewrite the generated results section of docs/v1.1/editor/ai-eval.md
#   --update-baseline  record this run as tool/eval/baseline.json (after a reviewed improvement)
# Env:   DANAVIEW_CI_CACHE_DIR (default ~/.cache/danaview-ci), DV_CMAKE, DV_EVAL_THREADS,
#        DV_EVAL_VAD_THRESHOLD / DV_EVAL_NO_SPEECH_THRESHOLD (tuning sweeps; never gate a release).
# Reports: packages/danaview_transcription/build/ai_eval/{smoke,models}/report.{json,md}.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PKG="$ROOT/packages/danaview_transcription"
EVAL="$PKG/tool/eval"
BUILD="$PKG/build/eval_runner"
OUT="$PKG/build/ai_eval"

DOWNLOAD=0
SMOKE_ONLY=0
BUILD_ONLY=0
WRITE_DOC=0
UPDATE_BASELINE=0
TIERS="fast,balanced,accurate"
JOBS="${DV_JOBS:-3}"
while [ $# -gt 0 ]; do
  case "$1" in
    --download-models) DOWNLOAD=1; shift ;;
    --smoke-only) SMOKE_ONLY=1; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --write-doc) WRITE_DOC=1; shift ;;
    --update-baseline) UPDATE_BASELINE=1; shift ;;
    --tiers) TIERS="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then DOWNLOAD=1; fi

CACHE_ROOT="${DANAVIEW_CI_CACHE_DIR:-$HOME/.cache/danaview-ci}"
MODEL_CACHE="$CACHE_ROOT/whisper"
CLIP_CACHE="$CACHE_ROOT/ai-eval-clips"

group() { if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::group::$1"; else echo "== $1"; fi; }
endgroup() { if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::endgroup::"; fi; }
notice() { if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::notice title=ai_eval::$1"; else echo "note: $1"; fi; }
fail() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::error title=ai_eval::$1"; else echo "error: $1" >&2; fi
  exit 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
size_of() { wc -c < "$1" | tr -d ' '; }
verified() {  # path bytes sha256
  [ -f "$1" ] && [ "$(size_of "$1")" = "$2" ] && [ "$(sha256_of "$1")" = "$3" ]
}

# --- 1. build the runner --------------------------------------------------------------------------
CMAKE="${DV_CMAKE:-}"
if [ -z "$CMAKE" ]; then
  if command -v cmake >/dev/null 2>&1; then
    CMAKE="$(command -v cmake)"
  else
    for c in "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/cmake/*/bin/cmake "$HOME/Android/Sdk"/cmake/*/bin/cmake; do
      if [ -x "$c" ]; then CMAKE="$c"; fi
    done
  fi
fi
[ -n "$CMAKE" ] || fail "cmake not found: install it (macOS: brew install cmake; Ubuntu: sudo apt-get install cmake ninja-build) or set DV_CMAKE"
GEN_ARGS=()
if command -v ninja >/dev/null 2>&1; then
  GEN_ARGS=(-G Ninja "-DCMAKE_MAKE_PROGRAM=$(command -v ninja)")
elif [ -x "$(dirname "$CMAKE")/ninja" ]; then
  GEN_ARGS=(-G Ninja "-DCMAKE_MAKE_PROGRAM=$(dirname "$CMAKE")/ninja")
fi

group "build dv_eval_runner (${BUILD#"$ROOT"/})"
"$CMAKE" -S "$EVAL/native" -B "$BUILD" ${GEN_ARGS[@]+"${GEN_ARGS[@]}"} -DCMAKE_BUILD_TYPE=Release >/dev/null
"$CMAKE" --build "$BUILD" --target dv_eval_runner -j "$JOBS" >/dev/null
RUNNER="$BUILD/dv_eval_runner"
[ -x "$RUNNER" ] || fail "dv_eval_runner was not built"
echo "ok: $RUNNER"
endgroup
if [ "$BUILD_ONLY" = "1" ]; then exit 0; fi

# --- 2. models ------------------------------------------------------------------------------------
# name|url|bytes|sha256 (ARCH §16.2; the same pins as SpeechModelCatalog, checked by tool/eval/test/tuning_test.dart)
MODELS="ggml-tiny-q5_1.bin|https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-tiny-q5_1.bin|32152673|818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7
ggml-base-q5_1.bin|https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base-q5_1.bin|59707625|422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898
ggml-small-q5_1.bin|https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q5_1.bin|190085487|ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb
ggml-silero-v6.2.0.bin|https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin|885098|2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

tier_file() {
  case "$1" in
    fast) echo ggml-tiny-q5_1.bin ;;
    balanced) echo ggml-base-q5_1.bin ;;
    accurate) echo ggml-small-q5_1.bin ;;
    *) echo "" ;;
  esac
}

if [ "$SMOKE_ONLY" = "0" ]; then
  group "models (${MODEL_CACHE})"
  mkdir -p "$MODEL_CACHE"
  wanted=" ggml-silero-v6.2.0.bin "
  IFS=',' read -r -a tier_list <<< "$TIERS"
  for t in "${tier_list[@]}"; do
    f="$(tier_file "$t")"
    [ -n "$f" ] || fail "unknown tier '$t' (fast, balanced, accurate)"
    wanted="$wanted$f "
  done
  while IFS='|' read -r name url bytes sha; do
    case "$wanted" in *" $name "*) ;; *) continue ;; esac
    dest="$MODEL_CACHE/$name"
    if verified "$dest" "$bytes" "$sha"; then
      echo "$name: cached, sha256 ok"
    elif [ "$DOWNLOAD" = "1" ]; then
      echo "$name: downloading ($bytes bytes)"
      rm -f "$dest.part"
      curl -fsSL --retry 3 --retry-delay 2 -o "$dest.part" "$url"
      verified "$dest.part" "$bytes" "$sha" || { rm -f "$dest.part"; fail "$name: size or sha256 mismatch"; }
      mv "$dest.part" "$dest"
    else
      rm -f "$dest"
      echo "$name: not cached (use --download-models or run in CI)"
    fi
  done <<< "$MODELS"
  endgroup

  # --- 3. remote eval clips -----------------------------------------------------------------------
  group "remote eval clips (${CLIP_CACHE})"
  mkdir -p "$CLIP_CACHE"
  remote="$(python3 -I -c '
import json, sys
doc = json.load(open(sys.argv[1]))
for c in doc.get("clips", []):
    if c.get("source") == "remote":
        print("|".join([c["id"], c["url"], str(c["bytes"]), c["sha256"]]))
' "$EVAL/eval_set.json")"
  if [ -z "$remote" ]; then
    echo "no remote clips in the manifest"
  else
    while IFS='|' read -r id url bytes sha; do
      src="$CLIP_CACHE/$id.src"
      wav="$CLIP_CACHE/$id.wav"
      if ! verified "$src" "$bytes" "$sha"; then
        if [ "$DOWNLOAD" = "1" ]; then
          rm -f "$src.part"
          curl -fsSL --retry 3 --retry-delay 2 -o "$src.part" "$url"
          verified "$src.part" "$bytes" "$sha" || { rm -f "$src.part"; fail "$id: size or sha256 mismatch"; }
          mv "$src.part" "$src"
          rm -f "$wav"
        else
          echo "$id: not cached (skipped)"
          continue
        fi
      fi
      if [ ! -f "$wav" ]; then
        if command -v ffmpeg >/dev/null 2>&1; then
          ffmpeg -nostdin -loglevel error -y -i "$src" -ac 1 -ar 16000 -c:a pcm_s16le -map_metadata -1 -fflags +bitexact "$wav"
        elif command -v afconvert >/dev/null 2>&1; then
          afconvert -f WAVE -d LEI16@16000 -c 1 "$src" "$wav"
        else
          fail "$id: neither ffmpeg nor afconvert is available to convert the clip"
        fi
      fi
      echo "$id: ok"
    done <<< "$remote"
  fi
  endgroup
fi

# --- 4/5. eval runs -------------------------------------------------------------------------------
cd "$PKG"
flutter pub get >/dev/null

group "smoke eval (fixture model)"
DV_EVAL_RUNNER="$RUNNER" DV_EVAL_SMOKE=1 DV_EVAL_OUT="$OUT/smoke" \
  flutter test tool/eval/eval_run_test.dart --reporter expanded
endgroup
if [ "$SMOKE_ONLY" = "1" ]; then exit 0; fi

have=""
IFS=',' read -r -a tier_list <<< "$TIERS"
for t in "${tier_list[@]}"; do
  if [ -f "$MODEL_CACHE/$(tier_file "$t")" ]; then have="${have:+$have,}$t"; fi
done
if [ -z "$have" ]; then
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then fail "no tier model available after the download step"; fi
  notice "accuracy eval skipped: no tier model in $MODEL_CACHE (run with --download-models)"
  exit 0
fi

EVAL_ENV=(
  "DV_EVAL_RUNNER=$RUNNER" "DV_EVAL_MODELS_DIR=$MODEL_CACHE" "DV_EVAL_CLIP_CACHE=$CLIP_CACHE"
  "DV_EVAL_TIERS=$have" "DV_EVAL_OUT=$OUT/models" "DV_EVAL_BASELINE=$EVAL/baseline.json"
)
if [ -n "${DV_EVAL_THREADS:-}" ]; then EVAL_ENV+=("DV_EVAL_THREADS=$DV_EVAL_THREADS"); fi
if [ "$WRITE_DOC" = "1" ]; then EVAL_ENV+=("DV_EVAL_WRITE_DOC=$ROOT/docs/v1.1/editor/ai-eval.md"); fi
if [ "$UPDATE_BASELINE" = "1" ]; then EVAL_ENV+=("DV_EVAL_UPDATE_BASELINE=1"); fi

group "accuracy eval (tiers: $have)"
env "${EVAL_ENV[@]}" flutter test tool/eval/eval_run_test.dart --reporter expanded
endgroup
echo "ai_eval: reports in ${OUT#"$ROOT"/}/{smoke,models}/"
