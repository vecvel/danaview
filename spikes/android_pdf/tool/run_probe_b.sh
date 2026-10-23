#!/usr/bin/env bash
# Run the HOM-27 route (b) probe on one device:
#   tool/run_probe_b.sh <serial> <label> [apk, default build/probe_b/full-r8.apk]
# Results: build/results/<label>.log (HOM27 json lines) and build/results/<label>/ (output PDFs).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
SERIAL="$1"; LABEL="$2"; APK="${3:-$HERE/build/probe_b/full-r8.apk}"
PKG=dev.danaview.spike.hom27b
ADB=(adb -s "$SERIAL")
RES="$HERE/build/results"
mkdir -p "$RES"
export MSYS_NO_PATHCONV=1
"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
"${ADB[@]}" install -t "$APK" >/dev/null
"${ADB[@]}" shell mkdir -p /data/local/tmp/hom27b
"${ADB[@]}" shell run-as "$PKG" mkdir -p files/in files/out
for f in "$HERE"/fixtures/*.pdf; do
  n=$(basename "$f")
  "${ADB[@]}" push "$f" "/data/local/tmp/hom27b/$n" >/dev/null
  "${ADB[@]}" shell "cat /data/local/tmp/hom27b/$n | run-as $PKG sh -c 'cat > files/in/$n'"
done
"${ADB[@]}" shell am instrument -w "$PKG/.Hom27PdfBox" | tr -d '\r' | tail -3
rm -rf "$RES/$LABEL" && mkdir -p "$RES/$LABEL"
for n in $("${ADB[@]}" shell run-as "$PKG" ls files/out | tr -d '\r'); do
  "${ADB[@]}" exec-out run-as "$PKG" cat "files/out/$n" > "$RES/$LABEL/$n"
done
cp "$RES/$LABEL/results.log" "$RES/$LABEL.log"
"${ADB[@]}" shell rm -rf /data/local/tmp/hom27b
"${ADB[@]}" uninstall "$PKG" >/dev/null
