#!/usr/bin/env bash
# OWNER: ENG-09
#
# android-unit CI job (ARCH §22, BUILD_PLAN ENG-09):
#
#   1. `flutter build apk` of the editor engine example host (release by default; the example
#      signs release builds with the debug key);
#   2. the plugin's JVM unit tests through the example's Gradle build:
#      ./gradlew :danaview_editor_engine:testDebugUnitTest. The example's danaview_test_harness.gradle
#      adds the ENG-05 barcode reader source root and passes the shared fixture roots
#      (danaview.fixtures*, see JvmFixtures.kt).
#
# Usage:
#   scripts/ci/editor/android_unit.sh
#
# Environment:
#   DANAVIEW_ANDROID_APK_MODE  release (default), debug, or none to skip the APK build
#   DANAVIEW_GRADLE_ARGS       extra Gradle arguments (CI adds --no-daemon)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EXAMPLE="$ROOT/packages/danaview_editor_engine/example"
MODE="${DANAVIEW_ANDROID_APK_MODE:-release}"

GHA="${GITHUB_ACTIONS:-}"
group() { if [ "$GHA" = true ]; then echo "::group::$1"; else echo "==> $1"; fi; }
endgroup() { if [ "$GHA" = true ]; then echo "::endgroup::"; fi; }
die() { if [ "$GHA" = true ]; then echo "::error title=android-unit::$1"; else echo "error: $1" >&2; fi; exit 1; }

case "${1:-}" in
  -h | --help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "unknown argument $1" >&2; exit 2 ;;
esac

command -v flutter >/dev/null || die "flutter not found: install Flutter 3.44.2"
command -v java >/dev/null || die "java not found: install JDK 17 (Temurin)"

declare -a GRADLE_ARGS=()
if [ "$GHA" = true ]; then GRADLE_ARGS+=(--no-daemon); fi
for a in ${DANAVIEW_GRADLE_ARGS:-}; do GRADLE_ARGS+=("$a"); done

group "flutter pub get (example)"
(cd "$EXAMPLE" && flutter pub get)
endgroup

case "$MODE" in
  release | debug)
    group "flutter build apk --$MODE (example)"
    (cd "$EXAMPLE" && flutter build apk "--$MODE")
    endgroup
    ;;
  none)
    group "flutter build apk --config-only (example)"
    (cd "$EXAMPLE" && flutter build apk --debug --config-only)
    endgroup
    ;;
  *) die "DANAVIEW_ANDROID_APK_MODE must be release, debug or none (got '$MODE')" ;;
esac

[ -x "$EXAMPLE/android/gradlew" ] || die "example/android/gradlew missing after the Flutter build"

group "plugin JVM unit tests (:danaview_editor_engine:testDebugUnitTest)"
(cd "$EXAMPLE/android" && ./gradlew "${GRADLE_ARGS[@]+"${GRADLE_ARGS[@]}"}" :danaview_editor_engine:testDebugUnitTest)
endgroup

echo "android-unit: OK"
