#!/usr/bin/env bash
# AIS-44 Android half: install the "sherpa" size app and run its FFI smoke
# (stock sherpa_onnx Dart package, DynamicLibrary.open inside a Flutter release app).
# Usage: android/size/smoke.sh <serial>
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
S=$1; A="adb -s $S"
M=${DANAVIEW_DIARIZATION_MODELS:-C:/dev/models/diarization}
ABI=$($A shell getprop ro.product.cpu.abi | tr -d '\r')
PKG=com.vecvel.ais44size
D=/sdcard/Android/data/$PKG/files
$A install -r build/size_app/sherpa/build/app/outputs/flutter-apk/app-$ABI-release.apk >/dev/null
$A shell am start -W -n $PKG/.MainActivity >/dev/null  # app creates its files dir
$A shell am force-stop $PKG
$A push "$M/segmentation/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx" $D/seg.int8.onnx >/dev/null
$A push "$M/nemo_en_titanet_small.onnx" $D/ >/dev/null
$A push data/c2_2spk_overlap.wav $D/ >/dev/null
$A logcat -c
$A shell am start -W -n $PKG/.MainActivity >/dev/null
for i in $(seq 1 60); do
  L=$($A logcat -d | grep -E 'AIS44SMOKE|AIS44FILE' || true)
  echo "$L" | grep -q AIS44SMOKE && { echo "$L"; break; }
  sleep 2
done
$A shell am force-stop $PKG
$A uninstall $PKG >/dev/null
