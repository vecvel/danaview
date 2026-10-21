#!/usr/bin/env bash
# AIS-44 spike: real-time factor and peak memory on the ~9-minute 4-speaker clip,
# per embedding model and thread count (int8 segmentation, threshold 0.5).
set -euo pipefail
cd "$(dirname "$0")/.."
M=${DANAVIEW_DIARIZATION_MODELS:-$HOME/danaview-models/diarization}
export SHERPA_LIB_DIR=${SHERPA_LIB_DIR:-$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_macos-1.13.8/macos}
SEG=$M/segmentation/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx
mkdir -p results
: > results/rtf_rss.txt
for e in ${EMBS:-nemo_en_titanet_small wespeaker_en_voxceleb_resnet34_LM 3dspeaker_speech_campplus_sv_en_voxceleb_16k}; do
  for t in ${THREADS_LIST:-1 2 4}; do
    tag="rtf.$e.t$t"
    /usr/bin/time -l build/diarize --threads $t --seg "$SEG" --emb "$M/$e.onnx" \
      --threshold ${TH:-0.5} --out "results/$tag.json" data/l1_4spk_long.wav 2> "results/$tag.log"
    echo "$tag $(grep -E 'maximum resident' results/$tag.log | awk '{print $1}') $(grep -o 'RTF [0-9.]*' results/$tag.log)" >> results/rtf_rss.txt
  done
done
cat results/rtf_rss.txt
