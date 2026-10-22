#!/usr/bin/env bash
# Build the HOM-27 route (b) probe APKs from the SDK only (javac, R8/D8 from build-tools, aapt2,
# zipalign, apksigner). No Gradle and no downloads: the PdfBox-Android AAR and its BouncyCastle jars
# must already be in build/m2/ (owner-approved download, recorded with SHA-256 in REPORT.md).
# Outputs in build/probe_b/: full-r8.apk (run + size), full-d8.apk (unshrunk size), empty-r8.apk (baseline).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
: "${ANDROID_HOME:?source ~/danaview_env.sh first}"
BT="$(cygpath -m "$ANDROID_HOME")/build-tools/${HOM27_BUILD_TOOLS:-36.0.0}"
AJ="$(cygpath -m "$ANDROID_HOME")/platforms/${HOM27_PLATFORM:-android-35}/android.jar"
M2="$HERE/build/m2"
OUT="$HERE/build/probe_b"
AAR="$OUT/aar"
rm -rf "$OUT" && mkdir -p "$AAR"
(cd "$AAR" && unzip -oq "$M2/pdfbox-android-2.0.27.0.aar")
LIBS=("$AAR/classes.jar" "$M2/bcprov-jdk15to18-1.72.jar" "$M2/bcpkix-jdk15to18-1.72.jar" "$M2/bcutil-jdk15to18-1.72.jar")
CP="$AJ;$(IFS=';'; echo "${LIBS[*]}")"
KS="$(cygpath -m "$HOME")/.android/debug.keystore"

build() { # <variant> <src dir> <with pdfbox: yes|no> <dexer: r8|d8>
  local v=$1 src=$2 lib=$3 dexer=$4 w="$OUT/$1"
  mkdir -p "$w/classes" "$w/dex"
  javac --release 11 -nowarn -cp "$CP" -d "$w/classes" $(find "$src" -name '*.java')
  (cd "$w/classes" && jar cf ../probe.jar .)
  local inputs=("$w/probe.jar")
  [ "$lib" = yes ] && inputs+=("${LIBS[@]}")
  if [ "$dexer" = r8 ]; then
    local rules=(--pg-conf "$HERE/probe_b/proguard-rules.pro")
    [ "$lib" = yes ] && rules+=(--pg-conf "$AAR/proguard.txt")
    java -Xmx2g -cp "$BT/lib/d8.jar" com.android.tools.r8.R8 --release --min-api 24 --lib "$AJ" \
      "${rules[@]}" --pg-map-output "$w/mapping.txt" --output "$w/dex" "${inputs[@]}"
  else
    java -Xmx2g -cp "$BT/lib/d8.jar" com.android.tools.r8.D8 --release --min-api 24 --lib "$AJ" \
      --output "$w/dex" "${inputs[@]}"
  fi
  local assets=()
  [ "$lib" = yes ] && assets=(-A "$AAR/assets")
  "$BT/aapt2" link --manifest "$HERE/probe_b/AndroidManifest.xml" -I "$AJ" "${assets[@]}" -o "$w/unsigned.apk"
  python3 -I -c "import sys,zipfile,glob,os
src=zipfile.ZipFile(sys.argv[1]); dst=zipfile.ZipFile(sys.argv[3],'w')
for i in src.infolist():
    dst.writestr(i.filename, src.read(i.filename), compress_type=i.compress_type)
for f in sorted(glob.glob(os.path.join(sys.argv[2],'*.dex'))): dst.write(f,os.path.basename(f),compress_type=zipfile.ZIP_DEFLATED)
dst.close()" "$w/unsigned.apk" "$w/dex" "$w/withdex.apk"
  "$BT/zipalign" -p -f 4 "$w/withdex.apk" "$w/aligned.apk"
  "$BT/apksigner.bat" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android --out "$OUT/$v.apk" "$w/aligned.apk"
  echo "$v.apk $(stat -c %s "$OUT/$v.apk") bytes, dex $(cat "$w"/dex/*.dex | wc -c) bytes"
}
build empty-r8 "$HERE/probe_b/empty" no r8
build full-r8 "$HERE/probe_b/src" yes r8
build full-d8 "$HERE/probe_b/src" yes d8
