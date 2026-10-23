#!/usr/bin/env bash
# VED-33A: run the bench on one device or emulator.
#   tool/run_bench.sh <serial> <label> [am instrument -e pairs, e.g. -e sections stills -e res 1080]
# Pushes the model pack (<models>/pack) and the face fixtures (/c/dev/models/faces) to the app's
# external files dir, runs FaceBench (app-all-release.apk, R8), pulls results/results.jsonl to
# build/results/<label>.jsonl (aggregates only), then deletes the fixtures, models and results from the
# device and uninstalls the app (fixture licence: nothing stays on the device after the test run).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SERIAL="$1"; LABEL="$2"; shift 2
MODELS="${VED33A_MODELS:-/c/dev/models/face_runtime}/pack"
FACES="${VED33A_FACES:-/c/dev/models/faces}"
APK="$(cygpath -m "${VED33A_APK:-$HERE/app/build/outputs/apk/all/release/app-all-release.apk}")"
PKG=com.vecvel.danaview.spike.face
EXT=/sdcard/Android/data/$PKG/files
ADB=(adb -s "$SERIAL")
RES="$HERE/build/results"
mkdir -p "$RES"
export MSYS_NO_PATHCONV=1
cleanup() {
  "${ADB[@]}" shell rm -rf "$EXT/faces" "$EXT/models" "$EXT/results" >/dev/null 2>&1 || true
  "${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
}
trap cleanup EXIT
"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
"${ADB[@]}" install -r -t "$APK" >/dev/null
"${ADB[@]}" shell am instrument -w -e prepare 1 "$PKG/.FaceBench" >/dev/null
"${ADB[@]}" push "$(cygpath -m "$MODELS")/." "$EXT/models/" >/dev/null
"${ADB[@]}" push "$(cygpath -m "$FACES")/stills" "$EXT/faces/" >/dev/null
"${ADB[@]}" push "$(cygpath -m "$FACES")/clips" "$EXT/faces/" >/dev/null
"${ADB[@]}" logcat -c
start=$(date +%s)
"${ADB[@]}" shell am instrument -w "$@" "$PKG/.FaceBench" | tr -d '\r' | tail -4
echo "wall $(( $(date +%s) - start )) s"
# Crash traces and the bench's own aggregate lines only.
"${ADB[@]}" logcat -d -s AndroidRuntime:E VED33A:* tflite:* DEBUG:* libc:* art:F onnxruntime:* > "$RES/$LABEL.logcat" || true
"${ADB[@]}" pull "$EXT/results/results.jsonl" "$(cygpath -m "$RES")/$LABEL.jsonl" >/dev/null
grep -c . "$RES/$LABEL.jsonl"
