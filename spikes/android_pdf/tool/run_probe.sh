#!/usr/bin/env bash
# Run the HOM-27 probe on one device: push the dex and fixtures, run, pull outputs.
#   tool/run_probe.sh <serial> <label> [run | verify <host dir of pdfs> | png <host dir of pdfs>]
# Results: build/results/<label>.log (HOM27 json lines) and build/results/<label>/ (output PDFs).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
SERIAL="$1"; LABEL="$2"; CMD="${3:-run}"
ADB=(adb -s "$SERIAL")
DEV=/data/local/tmp/hom27
RES="$HERE/build/results"
mkdir -p "$RES"
export MSYS_NO_PATHCONV=1
"${ADB[@]}" shell rm -rf "$DEV"
"${ADB[@]}" shell mkdir -p "$DEV/in" "$DEV/out"
"${ADB[@]}" push "$HERE/build/probe.dex" "$DEV/probe.dex" >/dev/null
if [ "$CMD" = run ]; then
  for f in "$HERE"/fixtures/*.pdf; do "${ADB[@]}" push "$f" "$DEV/in/" >/dev/null; done
  ARGS="run $DEV/in $DEV/out"
else
  for f in "$4"/*.pdf; do "${ADB[@]}" push "$f" "$DEV/in/" >/dev/null; done
  ARGS="$CMD $DEV/in $DEV/out"
fi
"${ADB[@]}" shell "CLASSPATH=$DEV/probe.dex app_process /system/bin Hom27Probe $ARGS" 2>&1 | tr -d '\r' | tee "$RES/$LABEL.log"
if [ "$CMD" != verify ]; then
  rm -rf "$RES/$LABEL" && mkdir -p "$RES/$LABEL"
  "${ADB[@]}" pull "$DEV/out/." "$RES/$LABEL/" >/dev/null
fi
"${ADB[@]}" shell rm -rf "$DEV"
