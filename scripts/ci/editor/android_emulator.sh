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
#   2. the example host's integration_test suites on the same device (they run even when a batch
#      failed), one `flutter test --no-uninstall` per file (FIX-CI-SUITES, from QA-03 / QA-11):
#      engine_smoke (ENG-09), android_preview (AND-10), QA-03's accuracy, av_sync and parity, and
#      QA-11's conformance, preset_matrix and audio_mix. Before the first QA-03 suite the ENG-05
#      media, the API-03 golden corpus and the committed iOS parity renders are pushed to the
#      app's external files dir (/sdcard/Android/data/<app>/files/qa03_*; the app is installed
#      first when needed) and passed as QA03_MEDIA / QA03_GOLDENS / QA03_PEER; parity writes its
#      renders to qa03_android there, pulled to example/build/danaview_emulator_suites/. A failed
#      file does not stop the others; a per-file summary is printed, each log is kept in
#      example/build/danaview_emulator_suites/<suite>.log, and the script exits non-zero if any
#      failed;
#   3. optional (DANAVIEW_E2E=1): QA-00's app-level E2E suite (integration_test/editor) through
#      integration_test/editor/tool/e2e_host.sh (stage, stage-models, run) on the same device.
#      Off by default: QA-02 certifies it by hand (scripts/ci/editor/README.md).
#
# Usage:
#   scripts/ci/editor/android_emulator.sh
#
# Environment:
#   ANDROID_SERIAL     the device to use (default: the only/first device `adb devices` lists)
#   DANAVIEW_GRADLE_ARGS  extra Gradle arguments (CI adds --no-daemon)
#   DV_PERF_STRICT=1   absolute performance limits in the instrumented tests (harness/PerfGate.kt)
#   DANAVIEW_EMULATOR_BATCHES  space-separated batches to run instead of every package, e.g.
#                      "effects proxy"; join packages with a comma to run them as one batch
#                      ("drop,harness")
#   DANAVIEW_SKIP_SMOKE=1  skip step 2 (every integration_test suite, not only the smoke test)
#   DANAVIEW_EMULATOR_SUITES  space-separated subset of step 2 (smoke android_preview accuracy
#                      av_sync parity conformance preset_matrix audio_mix)
#   DANAVIEW_E2E=1     run step 3; DANAVIEW_E2E_MODELS_DIR (or DV_E2E_MODELS_DIR) names the folder
#                      with the tiny speech models, DANAVIEW_E2E_TARGET the e2e_host.sh run target
#                      (default all)
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

# Step 2 suites: validated up front so a bad selection or missing media fails before the batches.
APP_ID="com.vecvel.danaview.editor.engine.example"
DEVICE_FILES="/sdcard/Android/data/$APP_ID/files"
MEDIA="$ROOT/packages/danaview_editor_engine/test_fixtures/media"
GOLDENS="$ROOT/packages/danaview_editor_engine_api/test_fixtures/images"
PEER_IOS="$ROOT/docs/v1.1/editor/qa/QA-03-parity/ios"
SUITE_OUT="$EXAMPLE/build/danaview_emulator_suites"
E2E_HOST="$ROOT/integration_test/editor/tool/e2e_host.sh"
ALL_SUITES="smoke android_preview accuracy av_sync parity conformance preset_matrix audio_mix"
suite_file() { if [ "$1" = smoke ]; then echo engine_smoke_test.dart; else echo "$1_test.dart"; fi; }
needs_media() { case "$1" in accuracy | av_sync | parity) return 0 ;; *) return 1 ;; esac; }
declare -a SUITES=()
if [ "${DANAVIEW_SKIP_SMOKE:-}" != 1 ]; then
  for s in ${DANAVIEW_EMULATOR_SUITES:-$ALL_SUITES}; do
    case " $ALL_SUITES " in *" $s "*) ;; *) die "DANAVIEW_EMULATOR_SUITES: unknown suite $s (known: $ALL_SUITES)" ;; esac
    [ -f "$EXAMPLE/integration_test/$(suite_file "$s")" ] || die "example/integration_test/$(suite_file "$s") is missing (suite $s)"
    if needs_media "$s"; then
      [ -f "$MEDIA/manifest.json" ] || die "ENG-05 media not found at ${MEDIA#"$ROOT"/} (QA-03 suites would only skip)"
    fi
    if [ "$s" = parity ]; then
      [ -f "$GOLDENS/goldens.json" ] || die "API-03 golden corpus not found at ${GOLDENS#"$ROOT"/}"
    fi
    SUITES+=("$s")
  done
fi
if [ "${DANAVIEW_E2E:-}" = 1 ] && [ ! -f "$E2E_HOST" ]; then
  die "DANAVIEW_E2E=1 but ${E2E_HOST#"$ROOT"/} is missing (QA-00)"
fi

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
  # Emulator readiness (emulator_ensure / emulator_booted / emulator_relaunch): an emulator that
  # stops answering during a batch or suite is relaunched (CI sets DANAVIEW_EMULATOR_AVD) and that
  # batch or suite runs once more; a device that is not an emulator is only waited for.
  # shellcheck source=emulator_ready.sh
  source "$ROOT/scripts/ci/editor/emulator_ready.sh"
  endgroup
else
  SERIAL="${ANDROID_SERIAL:-<serial>}"
  echo "dry run (DANAVIEW_EMULATOR_DRY_RUN=1): no device, no build"
fi

declare -a GRADLE_ARGS=()
if [ "$GHA" = true ]; then GRADLE_ARGS+=(--no-daemon); fi
# Absolute performance limits of the instrumented tests only with DV_PERF_STRICT=1 (PerfGate.kt).
if [ "${DV_PERF_STRICT:-}" = 1 ]; then GRADLE_ARGS+=("-Pandroid.testInstrumentationRunnerArguments.DV_PERF_STRICT=1"); fi
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
    for attempt in 1 2; do
      status=PASS
      emulator_ensure || true
      rm -rf "$RESULTS_SRC"
      if ! run "$EXAMPLE/android" ./gradlew "${GRADLE_ARGS[@]+"${GRADLE_ARGS[@]}"}" :danaview_editor_engine:connectedDebugAndroidTest \
        "-Pandroid.testInstrumentationRunnerArguments.package=$pkgs"; then
        status=FAIL
      fi
      # The emulator went away during the batch: relaunch it and run the batch once more.
      if [ "$status" = FAIL ] && [ "$attempt" = 1 ] && ! emulator_booted; then
        fail_note "the emulator stopped answering during batch $label; relaunching it and running the batch again"
        emulator_ensure && continue
      fi
      break
    done
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

# --- 2. integration_test suites (one flutter test per file; a failure does not stop the rest) ---
# Git Bash (Windows lane) rewrites arguments that start with /: keep device paths as they are while
# host paths are still converted for the native adb/flutter. No effect on macOS or Linux.
export MSYS2_ARG_CONV_EXCL="/sdcard;--dart-define=QA03_"
adb_do() { if [ "$DRY_RUN" = 1 ]; then echo "+ adb -s $SERIAL $*"; else "$ADB" -s "$SERIAL" "$@"; fi; }

# Prints "<passed> <failed> <skipped>" from the last flutter test progress line of a log
# ("mm:ss +P ~S -F: ..."), or "? ? ?".
progress_counts() {
  local line
  line="$(grep -E '^[0-9]+:[0-9]+ \+[0-9]+' "$1" 2>/dev/null | tail -n 1 || true)"
  if [ -z "$line" ]; then echo "? ? ?"; return; fi
  echo "$line" | awk '{
    p = 0; s = 0; f = 0
    for (i = 2; i <= NF; i++) {
      t = $i; sub(/:$/, "", t)
      if (t ~ /^\+[0-9]+$/) p = substr(t, 2) + 0
      else if (t ~ /^~[0-9]+$/) s = substr(t, 2) + 0
      else if (t ~ /^-[0-9]+$/) f = substr(t, 2) + 0
      else break
    }
    print p, f, s }'
}

# Pushes the QA-03 inputs into the app's external files dir. `flutter test --no-uninstall` keeps
# the app (and the dir) between suites; when the app is not installed yet, the example's debug APK
# is installed first so the dir belongs to the app.
MEDIA_PUSHED=false
push_qa03_media() {
  [ "$MEDIA_PUSHED" = true ] && return 0
  group "push QA-03 media to $DEVICE_FILES"
  if [ "$DRY_RUN" != 1 ] && [ -z "$("$ADB" -s "$SERIAL" shell pm path "$APP_ID" 2>/dev/null | tr -d '\r')" ]; then
    run "$EXAMPLE" flutter build apk --debug
    adb_do install -r -t "$EXAMPLE/build/app/outputs/flutter-apk/app-debug.apk"
  fi
  adb_do shell rm -rf "$DEVICE_FILES/qa03_media" "$DEVICE_FILES/qa03_goldens" "$DEVICE_FILES/qa03_peer_ios" "$DEVICE_FILES/qa03_android"
  adb_do shell mkdir -p "$DEVICE_FILES"
  adb_do push "$MEDIA" "$DEVICE_FILES/qa03_media"
  adb_do push "$GOLDENS" "$DEVICE_FILES/qa03_goldens"
  if [ -d "$PEER_IOS" ]; then adb_do push "$PEER_IOS" "$DEVICE_FILES/qa03_peer_ios"; fi
  MEDIA_PUSHED=true
  endgroup
}

suite_defines() {
  case "$1" in
    accuracy | av_sync) echo "--dart-define=QA03_MEDIA=$DEVICE_FILES/qa03_media" ;;
    parity)
      echo "--dart-define=QA03_MEDIA=$DEVICE_FILES/qa03_media"
      echo "--dart-define=QA03_GOLDENS=$DEVICE_FILES/qa03_goldens"
      echo "--dart-define=QA03_OUT=$DEVICE_FILES/qa03_android"
      if [ -d "$PEER_IOS" ]; then echo "--dart-define=QA03_PEER=$DEVICE_FILES/qa03_peer_ios"; fi
      ;;
  esac
}

declare -a SUITE_SUMMARY=()
SUITES_FAILED=0
if [ "${#SUITES[@]}" -eq 0 ]; then
  echo "integration_test suites skipped (DANAVIEW_SKIP_SMOKE=1)"
else
  if [ "$DRY_RUN" != 1 ]; then rm -rf "$SUITE_OUT"; mkdir -p "$SUITE_OUT"; fi
  for s in "${SUITES[@]}"; do
    if needs_media "$s"; then push_qa03_media; fi
    f="$(suite_file "$s")"
    declare -a D=()
    while IFS= read -r line; do [ -n "$line" ] && D+=("$line"); done < <(suite_defines "$s")
    logf="$SUITE_OUT/$s.log"
    group "integration_test/$f"
    started=$SECONDS
    if [ "$DRY_RUN" = 1 ]; then
      run "$EXAMPLE" flutter test "integration_test/$f" -d "$SERIAL" --no-uninstall ${D[@]+"${D[@]}"}
      status=DRY passed="-" failures="-" skipped="-"
    else
      for attempt in 1 2; do
        status=PASS
        emulator_ensure || true
        if ! (cd "$EXAMPLE" && flutter test "integration_test/$f" -d "$SERIAL" --no-uninstall ${D[@]+"${D[@]}"}) 2>&1 | tee "$logf"; then
          status=FAIL
        fi
        # The emulator went away during the suite: relaunch it (media pushed again) and rerun once.
        if [ "$status" = FAIL ] && [ "$attempt" = 1 ] && ! emulator_booted; then
          fail_note "the emulator stopped answering during integration_test/$f; relaunching it and running the suite again"
          if emulator_ensure; then
            if needs_media "$s"; then MEDIA_PUSHED=false; push_qa03_media; fi
            continue
          fi
        fi
        break
      done
      read -r passed failures skipped < <(progress_counts "$logf")
      if [ "$status" = FAIL ]; then
        SUITES_FAILED=$((SUITES_FAILED + 1))
        fail_note "integration_test/$f failed; log in ${logf#"$ROOT"/}"
      elif [ "$skipped" != "?" ] && [ "$skipped" -gt 0 ]; then
        echo "note: integration_test/$f skipped $skipped test(s); see ${logf#"$ROOT"/}"
      fi
    fi
    SUITE_SUMMARY+=("$(printf '%-16s %-5s %6s %6s %7s %7ss' "$s" "$status" "$passed" "$failures" "$skipped" "$((SECONDS - started))")")
    endgroup
  done
  if [ "$MEDIA_PUSHED" = true ] && [ -d "$PEER_IOS" ]; then
    case " ${SUITES[*]} " in
      *" parity "*)
        if [ "$DRY_RUN" = 1 ]; then echo "+ adb -s $SERIAL pull $DEVICE_FILES/qa03_android ${SUITE_OUT#"$ROOT"/}/"
        else "$ADB" -s "$SERIAL" pull "$DEVICE_FILES/qa03_android" "$SUITE_OUT/" >/dev/null 2>&1 || true; fi
        ;;
    esac
  fi
fi

# --- 3. QA-00 E2E suite (opt-in) ------------------------------------------------------------------
if [ "${DANAVIEW_E2E:-}" = 1 ]; then
  group "QA-00 E2E suite (integration_test/editor via e2e_host.sh)"
  started=$SECONDS
  status=PASS
  models="${DANAVIEW_E2E_MODELS_DIR:-${DV_E2E_MODELS_DIR:-}}"
  e2e_ok=true
  run "$ROOT" bash "$E2E_HOST" -p android -d "$SERIAL" stage || e2e_ok=false
  if [ "$e2e_ok" = true ] && [ -n "$models" ]; then
    run "$ROOT" bash "$E2E_HOST" -p android -d "$SERIAL" stage-models "$models" || e2e_ok=false
  fi
  if [ "$e2e_ok" = true ]; then
    run "$ROOT" bash "$E2E_HOST" -p android -d "$SERIAL" run "${DANAVIEW_E2E_TARGET:-all}" || e2e_ok=false
  fi
  if [ "$DRY_RUN" = 1 ]; then status=DRY
  elif [ "$e2e_ok" != true ]; then
    status=FAIL
    SUITES_FAILED=$((SUITES_FAILED + 1))
    fail_note "QA-00 E2E suite failed; evidence in build/e2e/android/$SERIAL/"
  fi
  SUITE_SUMMARY+=("$(printf '%-16s %-5s %6s %6s %7s %7ss' e2e "$status" - - - "$((SECONDS - started))")")
  endgroup
else
  echo "QA-00 E2E suite (integration_test/editor) not run: set DANAVIEW_E2E=1 (QA-02 certifies it by hand)"
fi

if [ "${#SUITE_SUMMARY[@]}" -gt 0 ]; then
  group "integration_test summary"
  printf '%-16s %-5s %6s %6s %7s %8s\n' suite result passed failed skipped time
  for row in "${SUITE_SUMMARY[@]}"; do echo "$row"; done
  echo "logs in ${SUITE_OUT#"$ROOT"/}/<suite>.log"
  endgroup
fi

[ "$SUITES_FAILED" -eq 0 ] || fail_note "$SUITES_FAILED integration_test suite(s) failed (see the summary above)"
if [ "$FAILED" -gt 0 ] || [ "$SUITES_FAILED" -gt 0 ]; then
  die "$FAILED of ${#BATCHES[@]} instrumented test batches and $SUITES_FAILED integration_test suite(s) failed"
fi
if [ "$DRY_RUN" = 1 ]; then echo "android-emulator: dry run done"; else echo "android-emulator: OK"; fi
