#!/usr/bin/env bash
# VED-33A: AAB download size per ABI for each candidate runtime (R8 release build, no models bundled).
#   tool/measure_size.sh [flavours...]   (default: none mp mp11 litert ort all)
# Needs bundletool (owner-approved download): BUNDLETOOL=/c/dev/models/tools/bundletool-all-1.18.3.jar
# Output: build/size/<flavour>.csv (bundletool get-size total --dimensions=ABI) + native lib listing.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
: "${ANDROID_HOME:?source ~/danaview_env.sh first}"
BT="${BUNDLETOOL:-/c/dev/models/tools/bundletool-all-1.18.3.jar}"
KS="$(cygpath -m "$HOME")/.android/debug.keystore"
OUT="$HERE/build/size"
mkdir -p "$OUT"
FLAVOURS=("${@:-none mp mp11 litert ort all}")
[ $# -eq 0 ] && FLAVOURS=(none mp mp11 litert ort all)
cd "$HERE"
for f in "${FLAVOURS[@]}"; do
  F="$(tr '[:lower:]' '[:upper:]' <<< "${f:0:1}")${f:1}"
  ./gradlew --no-daemon -q ":app:bundle${F}Release"
  aab="app/build/outputs/bundle/${f}Release/app-${f}-release.aab"
  rm -f "$OUT/$f.apks"
  java -jar "$BT" build-apks --bundle="$aab" --output="$OUT/$f.apks" \
    --ks="$KS" --ks-pass=pass:android --ks-key-alias=androiddebugkey --key-pass=pass:android >/dev/null
  java -jar "$BT" get-size total --apks="$OUT/$f.apks" --dimensions=ABI > "$OUT/$f.csv"
  unzip -l "$aab" | awk '/\.so$/ {print $1, $4}' > "$OUT/$f.so.txt"
  unzip -l "$aab" | awk '/\.dex$/ {s+=$1} END {print "dex", s}' >> "$OUT/$f.so.txt"
  echo "== $f ($(stat -c %s "$aab") bytes AAB)"; cat "$OUT/$f.csv"
done
