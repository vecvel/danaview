#!/usr/bin/env bash
# AIS-44 spike: run the accuracy grid (embedding model x segmentation model x
# clustering mode) on the short clips, one process per run, and record peak
# memory with /usr/bin/time -l. Results land in results/ (git-ignored).
#
# Needs: python3 tool/make_clips.py, and build/diarize from
#   dart compile exe bin/diarize.dart -o build/diarize
# Models are read from $DANAVIEW_DIARIZATION_MODELS (default ~/danaview-models/diarization).
set -euo pipefail
cd "$(dirname "$0")/.."
M=${DANAVIEW_DIARIZATION_MODELS:-$HOME/danaview-models/diarization}
export SHERPA_LIB_DIR=${SHERPA_LIB_DIR:-$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_macos-1.13.8/macos}
SEGDIR=$M/segmentation/sherpa-onnx-pyannote-segmentation-3-0
THREADS=${THREADS:-2}
mkdir -p results
TWO="data/c1_2spk_turns.wav data/c2_2spk_overlap.wav data/c5_2spk_similar.wav data/c6_2spk_male.wav"
THREE="data/c3_3spk_turns.wav data/c4_3spk_overlap.wav"
EMBS="3dspeaker_speech_campplus_sv_en_voxceleb_16k wespeaker_en_voxceleb_resnet34_LM nemo_en_titanet_small"
THS=${THS:-"0.3 0.4 0.5 0.6 0.7 0.8 0.9"}

run() { # tag, then diarize args
  local tag=$1; shift
  /usr/bin/time -l build/diarize --threads "$THREADS" --out "results/$tag.json" "$@" \
    2> "results/$tag.log"
  grep -E "maximum resident" "results/$tag.log" | awk -v t="$tag" '{print t, $1}' >> results/rss.txt
}

: > results/rss.txt
for e in $EMBS; do
  for s in model model.int8; do
    base="$e.$s"
    run "$base.k2" --seg "$SEGDIR/$s.onnx" --emb "$M/$e.onnx" --clusters 2 $TWO
    run "$base.k3" --seg "$SEGDIR/$s.onnx" --emb "$M/$e.onnx" --clusters 3 $THREE
    for th in $THS; do
      run "$base.th$th" --seg "$SEGDIR/$s.onnx" --emb "$M/$e.onnx" --threshold "$th" $TWO $THREE
    done
  done
done
echo done
