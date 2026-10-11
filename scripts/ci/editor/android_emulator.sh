#!/usr/bin/env bash
# OWNER: ENG-09
#
# android-emulator CI job (ARCH §22, BUILD_PLAN ENG-09). Runs on a booted emulator or device (CI:
# API 35 x86_64 through reactivecircus/android-emulator-runner):
#
#   1. the plugin's instrumented tests through the example's Gradle build:
#      ./gradlew :danaview_editor_engine:connectedDebugAndroidTest. The example's
#      danaview_test_harness.gradle packs the shared fixtures into the test APK's assets
#      (fixtures/engine, fixtures/core, fixtures/engine_api; see TestFixtures.kt);
#   2. integration_test/engine_smoke_test.dart of the example host on the same device.
#
# Usage:
#   scripts/ci/editor/android_emulator.sh
#
# Environment:
#   ANDROID_SERIAL     the device to use (default: the only/first device `adb devices` lists)
#   DANAVIEW_GRADLE_ARGS  extra Gradle arguments (CI adds --no-daemon)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EXAMPLE="$ROOT/packages/danaview_editor_engine/example"

GHA="${GITHUB_ACTIONS:-}"
group() { if [ "$GHA" = true ]; then echo "::group::$1"; else echo "==> $1"; fi; }
endgroup() { if [ "$GHA" = true ]; then echo "::endgroup::"; fi; }
die() { if [ "$GHA" = true ]; then echo "::error title=android-emulator::$1"; else echo "error: $1" >&2; fi; exit 1; }

case "${1:-}" in
  -h | --help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "unknown argument $1" >&2; exit 2 ;;
esac

command -v flutter >/dev/null || die "flutter not found: install Flutter 3.44.2"
ADB="$(command -v adb || true)"
for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
  [ -z "$ADB" ] && [ -n "$sdk" ] && [ -x "$sdk/platform-tools/adb" ] && ADB="$sdk/platform-tools/adb"
done
[ -n "$ADB" ] || die "adb not found: install the Android SDK platform-tools"

group "device"
SERIAL="${ANDROID_SERIAL:-}"
if [ -z "$SERIAL" ]; then
  SERIAL="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi
[ -n "$SERIAL" ] || die "no booted emulator or device (adb devices is empty); boot an API 35 emulator first"
export ANDROID_SERIAL="$SERIAL"
"$ADB" -s "$SERIAL" wait-for-device
for _ in $(seq 1 120); do
  [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break
  sleep 2
done
[ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] || die "$SERIAL did not finish booting"
echo "device $SERIAL, API $("$ADB" -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r'), $("$ADB" -s "$SERIAL" shell getprop ro.product.cpu.abi | tr -d '\r')"
endgroup

declare -a GRADLE_ARGS=()
if [ "$GHA" = true ]; then GRADLE_ARGS+=(--no-daemon); fi
for a in ${DANAVIEW_GRADLE_ARGS:-}; do GRADLE_ARGS+=("$a"); done

group "flutter pub get + Gradle config (example)"
(cd "$EXAMPLE" && flutter pub get && flutter build apk --debug --config-only)
[ -x "$EXAMPLE/android/gradlew" ] || die "example/android/gradlew missing after flutter build apk --config-only"
endgroup

group "plugin instrumented tests (:danaview_editor_engine:connectedDebugAndroidTest)"
(cd "$EXAMPLE/android" && ./gradlew "${GRADLE_ARGS[@]+"${GRADLE_ARGS[@]}"}" :danaview_editor_engine:connectedDebugAndroidTest)
endgroup

group "integration_test/engine_smoke_test.dart"
(cd "$EXAMPLE" && flutter test integration_test/engine_smoke_test.dart -d "$SERIAL")
endgroup

echo "android-emulator: OK"
