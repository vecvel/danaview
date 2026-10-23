#!/usr/bin/env bash
# AIS-44 Android half: install the Play Feature Delivery probe with bundletool
# --local-testing (base only; the "diarization" module is installed on demand by
# FakeSplitInstallManager) and run it. Prints the app's AIS44PFD log lines.
# Usage: android/pfd/run_pfd.sh <serial>
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
S=$1; A="adb -s $S"
M=${DANAVIEW_DIARIZATION_MODELS:-C:/dev/models/diarization}
PKG=com.vecvel.ais44size
D=/sdcard/Android/data/$PKG/files
$A uninstall $PKG >/dev/null 2>&1 || true
java -jar build/tools/bundletool-all-1.17.2.jar install-apks --apks=build/size_app/pfd-local.apks --device-id=$S
echo "installed packages:"; $A shell pm path $PKG
$A push "$M/segmentation/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx" $D/seg.int8.onnx >/dev/null
$A push "$M/nemo_en_titanet_small.onnx" $D/ >/dev/null
$A push data/c2_2spk_overlap.wav $D/ >/dev/null
$A logcat -c
$A shell am start -W -n $PKG/.MainActivity >/dev/null
for i in $(seq 1 90); do
  L=$($A logcat -d | grep -E 'AIS44PFD|SplitCompat|SplitInstall|FakeSplit' || true)
  echo "$L" | grep -qE 'AIS44PFD (done|fail)' && break
  sleep 2
done
echo "$L"
echo "after:"; $A shell pm path $PKG
$A shell am force-stop $PKG
$A uninstall $PKG >/dev/null
