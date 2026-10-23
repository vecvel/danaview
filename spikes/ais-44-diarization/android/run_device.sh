#!/usr/bin/env bash
# AIS-44 Android half: run diarize_probe on an emulator/device over adb.
# Usage: android/run_device.sh <serial> <tag> [short|long|huge|all]
# Pushes build/android/<abi>/ (probe + sherpa-onnx .so), the models from
# $DANAVIEW_DIARIZATION_MODELS (default C:/dev/models/diarization) and the clips
# to /data/local/tmp/ais44, runs one process per configuration, pulls the JSON
# to results/android/<tag>/ (git-ignored). Score with tool/score.py.
set -euo pipefail
export MSYS_NO_PATHCONV=1  # Git Bash: keep /data/local/tmp paths as-is
cd "$(dirname "$0")/.."
S=$1; TAG=$2; WHAT=${3:-all}
M=${DANAVIEW_DIARIZATION_MODELS:-C:/dev/models/diarization}
A="adb -s $S"
ABI=$($A shell getprop ro.product.cpu.abi | tr -d '\r')
R=/data/local/tmp/ais44
OUT=results/android/$TAG
mkdir -p "$OUT"
$A shell mkdir -p $R/m $R/d $R/o
if [ "${SKIP_PUSH:-0}" != 1 ]; then
  $A push build/android/$ABI/. $R/ >/dev/null
  $A push "$M/segmentation/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx" $R/m/seg.int8.onnx >/dev/null
  for e in nemo_en_titanet_small wespeaker_en_voxceleb_resnet34_LM 3dspeaker_speech_campplus_sv_en_voxceleb_16k; do
    $A push "$M/$e.onnx" $R/m/ >/dev/null
  done
  for c in c1_2spk_turns c2_2spk_overlap c4_3spk_overlap c5_2spk_similar a1_3spk_long a2_3spk_37min; do
    [ -f data/$c.wav ] && $A push data/$c.wav $R/d/ >/dev/null
  done
  $A shell chmod 755 $R/diarize_probe
fi
{ $A shell getprop ro.build.version.sdk; $A shell getprop ro.product.model; $A shell cat /proc/meminfo | head -3; $A shell nproc; } > "$OUT/device.txt"

run() { # name threads emb (clusters|threshold) value wav...
  local name=$1 t=$2 e=$3 mode=$4 v=$5; shift 5
  local w=""; for c in "$@"; do w="$w $R/d/$c.wav"; done
  echo "== $name" >&2
  $A shell "cd $R && LD_LIBRARY_PATH=$R ./diarize_probe --threads $t --seg m/seg.int8.onnx --emb m/$e.onnx --$mode $v --out o/$name.json $w" 2>&1 | tail -2 >&2
  $A pull $R/o/$name.json "$OUT/$name.json" >/dev/null
}

TWO="c1_2spk_turns c2_2spk_overlap c5_2spk_similar"
ALL="c1_2spk_turns c2_2spk_overlap c4_3spk_overlap c5_2spk_similar"
if [ "$WHAT" = short ] || [ "$WHAT" = all ]; then
  for e in nemo_en_titanet_small wespeaker_en_voxceleb_resnet34_LM 3dspeaker_speech_campplus_sv_en_voxceleb_16k; do
    run "$e.k2" 2 $e clusters 2 $TWO
    run "$e.k3" 2 $e clusters 3 c4_3spk_overlap
    for th in ${THS:-0.5 0.7}; do run "$e.th$th" 2 $e threshold $th $ALL; done
  done
fi
if [ "$WHAT" = long ] || [ "$WHAT" = all ]; then
  for e in nemo_en_titanet_small wespeaker_en_voxceleb_resnet34_LM; do
    for t in ${THREADS_LIST:-1 2 4}; do run "long.$e.t$t" $t $e threshold 0.7 a1_3spk_long; done
  done
fi
if [ "$WHAT" = huge ] || [ "$WHAT" = all ]; then
  run "huge.nemo_en_titanet_small.t2" 2 nemo_en_titanet_small threshold 0.7 a2_3spk_37min
fi
echo "results in $OUT"
