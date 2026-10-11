#!/usr/bin/env bash
# Builds the AND-01 spike host, runs its instrumented tests on a connected emulator/device without
# uninstalling (so results survive), and pulls results/*.json into spikes/android_engine/results/.
#
#   tool/run_spike.sh                      # every test class
#   tool/run_spike.sh GridTimingTest       # one class (simple name)
#   tool/run_spike.sh GridTimingTest#seekSemantics_vn18
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
SERIAL="${ANDROID_SERIAL:-$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')}"
PKG=com.vecvel.danaview.spike.engine
cd "$HERE"
[ -f media/barcode_30.mp4 ] || ./tool/gen_media.sh
./gradlew --console=plain -q :app:assembleDebug :app:assembleDebugAndroidTest
"$ADB" -s "$SERIAL" install -r -t app/build/outputs/apk/debug/app-debug.apk >/dev/null
"$ADB" -s "$SERIAL" install -r -t app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk >/dev/null
ARGS=()
if [ $# -gt 0 ]; then
  ARGS=(-e class "$PKG.$1")
fi
# The loaded emulator sometimes fails to start the instrumentation process right after install
# ("failed to attach"); retry a few times.
for attempt in 1 2 3; do
  # ${ARGS[@]+...}: an empty array is "unbound" under set -u in macOS's bash 3.2.
  "$ADB" -s "$SERIAL" shell am instrument -w -r ${ARGS[@]+"${ARGS[@]}"} "$PKG.test/androidx.test.runner.AndroidJUnitRunner" > "$HERE/build/last_run.txt" || true
  grep -q "failed to attach" "$HERE/build/last_run.txt" || break
  sleep 5
done
grep -E "INSTRUMENTATION_STATUS: (test|stack)=|INSTRUMENTATION_STATUS_CODE|OK \(|FAILURES|Tests run" "$HERE/build/last_run.txt" || true
mkdir -p "$HERE/results"
"$ADB" -s "$SERIAL" pull "/sdcard/Android/data/$PKG/files/results/." "$HERE/results/" >/dev/null 2>&1 || true
ls "$HERE/results"
