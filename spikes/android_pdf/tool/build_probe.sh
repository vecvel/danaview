#!/usr/bin/env bash
# Build the HOM-27 probe dex with the SDK only (javac + d8). No Gradle, no downloads.
# Output: spikes/android_pdf/build/probe.dex
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
: "${ANDROID_HOME:?source ~/danaview_env.sh first}"
PLATFORM="${HOM27_PLATFORM:-android-37.0}"
BT="${HOM27_BUILD_TOOLS:-36.0.0}"
OUT="$HERE/build"
rm -rf "$OUT/classes" && mkdir -p "$OUT/classes"
javac --release 11 -nowarn -cp "$ANDROID_HOME/platforms/$PLATFORM/android.jar" \
  -d "$OUT/classes" "$HERE/probe/src/Hom27Probe.java"
D8="$ANDROID_HOME/build-tools/$BT/d8"
[ -f "$D8.bat" ] && D8="$D8.bat"
"$D8" --min-api 24 --lib "$ANDROID_HOME/platforms/$PLATFORM/android.jar" \
  --output "$OUT" $(find "$OUT/classes" -name '*.class')
mv -f "$OUT/classes.dex" "$OUT/probe.dex"
echo "built $OUT/probe.dex"
