#!/usr/bin/env bash
# Builds the QA-02 manual input injector (src/Inject.java) into a dex and pushes it.
# Usage: spikes/qa02_manual/build.sh <serial>
# Needs ANDROID_HOME and JAVA_HOME (source ~/danaview_env.sh). Output goes to a temp dir.
set -euo pipefail
serial="$1"
here="$(cd "$(dirname "$0")" && pwd)"
out="$(cygpath -m "$(mktemp -d)")"
jar="$ANDROID_HOME/platforms/android-35/android.jar"
"$JAVA_HOME/bin/javac" --release 11 -cp "$jar" -d "$out" "$here/src/Inject.java"
"$ANDROID_HOME/build-tools/36.0.0/d8.bat" --min-api 33 --lib "$jar" --output "$out" "$out"/Inject*.class
MSYS_NO_PATHCONV=1 adb -s "$serial" push "$out/classes.dex" /data/local/tmp/qa02_inject.dex
rm -rf "$out"
echo "run: adb -s $serial shell CLASSPATH=/data/local/tmp/qa02_inject.dex app_process /system/bin Inject devices"
