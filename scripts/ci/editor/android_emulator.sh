#!/usr/bin/env bash
# OWNER: ENG-09
# Batching by test package: owner-directed change, 2026-10-15.
#
# android-emulator CI job (ARCH §22, BUILD_PLAN ENG-09). Runs on a booted emulator or device (CI:
# API 35 x86_64 through reactivecircus/android-emulator-runner):
#
#   1. the plugin's instrumented tests through the example's Gradle build, in batches: one
#      ./gradlew :danaview_editor_engine:connectedDebugAndroidTest per test package (each direct
#      subdirectory of android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/ that has
#      an @Test), filtered with -Pandroid.testInstrumentationRunnerArguments.package=<package>.
#      Each batch is its own instrumentation process, so a load-dependent failure or a native
#      crash in one batch cannot abort the others. A failed batch does not stop the run; a
#      per-batch summary (package, tests, failures, time) is printed at the end and the script
#      exits non-zero if any batch failed. Each batch's JUnit XML and logs are copied to
#      example/build/danaview_emulator_batches/<batch>/. The example's danaview_test_harness.gradle
#      packs the shared fixtures into the test APK's assets (fixtures/engine, fixtures/core,
#      fixtures/engine_api; see TestFixtures.kt);
#   2. integration_test/engine_smoke_test.dart of the example host on the same device (it runs
#      even when a batch failed).
#
# Usage:
#   scripts/ci/editor/android_emulator.sh
#
# Environment:
#   ANDROID_SERIAL     the device to use (default: the only/first device `adb devices` lists)
#   DANAVIEW_GRADLE_ARGS  extra Gradle arguments (CI adds --no-daemon)
#   DANAVIEW_EMULATOR_BATCHES  space-separated batches to run instead of every package, e.g.
#                      "effects proxy"; join packages with a comma to run them as one batch
#                      ("drop,harness")
#   DANAVIEW_SKIP_SMOKE=1  skip step 2
#   DANAVIEW_EMULATOR_DRY_RUN=1  print the batches and commands without a device or a build
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EXAMPLE="$ROOT/packages/danaview_editor_engine/example"
TEST_PKG="com.vecvel.danaview.editor.engine"
TEST_SRC="$ROOT/packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine"
RESULTS_SRC="$EXAMPLE/build/danaview_editor_engine/outputs/androidTest-results/connected"
RESULTS_DST="$EXAMPLE/build/danaview_emulator_batches"
DRY_RUN="${DANAVIEW_EMULATOR_DRY_RUN:-}"

GHA="${GITHUB_ACTIONS:-}"
group() { if [ "$GHA" = true ]; then echo "::group::$1"; else echo "==> $1"; fi; }
endgroup() { if [ "$GHA" = true ]; then echo "::endgroup::"; fi; }
die() { if [ "$GHA" = true ]; then echo "::error title=android-emulator::$1"; else echo "error: $1" >&2; fi; exit 1; }
fail_note() { if [ "$GHA" = true ]; then echo "::error title=android-emulator::$1"; else echo "error: $1" >&2; fi; }
run() { if [ "$DRY_RUN" = 1 ]; then echo "+ (cd $1 && ${*:2})"; else (cd "$1" && "${@:2}"); fi; }

case "${1:-}" in
  -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown argument $1" >&2; exit 2 ;;
esac

# Batches: every direct subdirectory of the androidTest tree that contains an @Test, or the
# DANAVIEW_EMULATOR_BATCHES override (each entry one batch; commas join packages).
[ -d "$TEST_SRC" ] || die "instrumented test sources not found at ${TEST_SRC#"$ROOT"/}"
declare -a BATCHES=()
if [ -n "${DANAVIEW_EMULATOR_BATCHES:-}" ]; then
  for b in $DANAVIEW_EMULATOR_BATCHES; do
    for p in $(echo "$b" | tr ',' ' '); do
      [ -d "$TEST_SRC/$p" ] || die "DANAVIEW_EMULATOR_BATCHES: no test package $p under ${TEST_SRC#"$ROOT"/}"
    done
    BATCHES+=("$b")
  done
else
  for d in "$TEST_SRC"/*/; do
    [ -d "$d" ] || continue
    if grep -rqE '^[[:space:]]*@Test' "$d"; then BATCHES+=("$(basename "$d")"); fi
  done
fi
[ "${#BATCHES[@]}" -gt 0 ] || die "no instrumented test packages found under ${TEST_SRC#"$ROOT"/}"

if [ "$DRY_RUN" != 1 ]; then
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
else
  SERIAL="${ANDROID_SERIAL:-<serial>}"
  echo "dry run (DANAVIEW_EMULATOR_DRY_RUN=1): no device, no build"
fi

declare -a GRADLE_ARGS=()
if [ "$GHA" = true ]; then GRADLE_ARGS+=(--no-daemon); fi
for a in ${DANAVIEW_GRADLE_ARGS:-}; do GRADLE_ARGS+=("$a"); done

group "flutter pub get + Gradle config (example)"
run "$EXAMPLE" flutter pub get
run "$EXAMPLE" flutter build apk --debug --config-only
if [ "$DRY_RUN" != 1 ]; then
  [ -x "$EXAMPLE/android/gradlew" ] || die "example/android/gradlew missing after flutter build apk --config-only"
fi
endgroup

# Sums an attribute over every <testsuite> in the batch's JUnit XML files; prints "?" without XML.
xml_sum() {
  local dir="$1" attr="$2" files
  files="$(find "$dir" -name '*.xml' -type f 2>/dev/null | grep -v '/testlog/' || true)"
  if [ -z "$files" ]; then echo "?"; return; fi
  echo "$files" | while IFS= read -r f; do cat "$f"; done |
    awk -v a="$attr" '
      /<testsuite[ >]/ {
        if (match($0, " " a "=\"[0-9]+\"")) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); n += s }
      }
      END { print n + 0 }'
}

declare -a SUMMARY=()
FAILED=0
if [ "$DRY_RUN" != 1 ]; then rm -rf "$RESULTS_DST"; mkdir -p "$RESULTS_DST"; fi
for b in "${BATCHES[@]}"; do
  label="$(echo "$b" | tr ',' '+')"
  pkgs=""
  for p in $(echo "$b" | tr ',' ' '); do pkgs="${pkgs:+$pkgs,}$TEST_PKG.$p"; done
  group "instrumented tests: $label (:danaview_editor_engine:connectedDebugAndroidTest)"
  started=$SECONDS
  status=PASS
  if [ "$DRY_RUN" = 1 ]; then
    run "$EXAMPLE/android" ./gradlew "${GRADLE_ARGS[@]+"${GRADLE_ARGS[@]}"}" :danaview_editor_engine:connectedDebugAndroidTest \
      "-Pandroid.testInstrumentationRunnerArguments.package=$pkgs"
    tests="-" failures="-" status=DRY
  else
    rm -rf "$RESULTS_SRC"
    if ! run "$EXAMPLE/android" ./gradlew "${GRADLE_ARGS[@]+"${GRADLE_ARGS[@]}"}" :danaview_editor_engine:connectedDebugAndroidTest \
      "-Pandroid.testInstrumentationRunnerArguments.package=$pkgs"; then
      status=FAIL
    fi
    mkdir -p "$RESULTS_DST/$label"
    if [ -d "$RESULTS_SRC" ]; then cp -R "$RESULTS_SRC/." "$RESULTS_DST/$label/"; fi
    tests="$(xml_sum "$RESULTS_DST/$label" tests)"
    f="$(xml_sum "$RESULTS_DST/$label" failures)"
    e="$(xml_sum "$RESULTS_DST/$label" errors)"
    if [ "$f" = "?" ]; then failures="?"; else failures=$((f + e)); fi
    if [ "$status" = PASS ] && [ "$failures" != "?" ] && [ "$failures" -gt 0 ]; then status=FAIL; fi
    if [ "$status" = PASS ] && [ "$tests" = "?" ]; then status=FAIL; fi
  fi
  elapsed=$((SECONDS - started))
  if [ "$status" = FAIL ]; then
    FAILED=$((FAILED + 1))
    fail_note "batch $label failed (tests $tests, failures $failures); results in ${RESULTS_DST#"$ROOT"/}/$label"
  fi
  SUMMARY+=("$(printf '%-24s %-5s %6s %9s %7ss' "$label" "$status" "$tests" "$failures" "$elapsed")")
  endgroup
done

group "instrumented test summary"
printf '%-24s %-5s %6s %9s %8s\n' batch result tests failures time
for line in "${SUMMARY[@]}"; do echo "$line"; done
echo "${#BATCHES[@]} batches, $FAILED failed; JUnit XML per batch in ${RESULTS_DST#"$ROOT"/}/<batch>/"
endgroup

if [ "${DANAVIEW_SKIP_SMOKE:-}" = 1 ]; then
  echo "integration_test/engine_smoke_test.dart skipped (DANAVIEW_SKIP_SMOKE=1)"
else
  group "integration_test/engine_smoke_test.dart"
  run "$EXAMPLE" flutter test integration_test/engine_smoke_test.dart -d "$SERIAL"
  endgroup
fi

[ "$FAILED" -eq 0 ] || die "$FAILED of ${#BATCHES[@]} instrumented test batches failed (see the summary above)"
if [ "$DRY_RUN" = 1 ]; then echo "android-emulator: dry run done"; else echo "android-emulator: OK"; fi
