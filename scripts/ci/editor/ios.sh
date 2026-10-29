#!/usr/bin/env bash
# OWNER: ENG-09
#
# ios CI job (ARCH §22, BUILD_PLAN ENG-09) on the self-hosted Mac (fallback macos-15):
#
#   1. toolchain: Xcode, Flutter, CocoaPods and CMake >= 3.28 (fails early with the
#      `brew install cmake` instruction; the whisper xcframework needs it, AI-05);
#   2. check_ios_min_os.sh --self-test (its negative and positive fixtures, D-41);
#   3. packages/danaview_whisper/tool/build_ios_xcframework.sh --if-missing, when that script exists;
#   4. `flutter build ios --no-codesign` of the engine example host (release, device);
#   5. check_ios_min_os.sh on the built Runner.app, the engine pod framework and
#      WhisperCore.xcframework (when built): nothing strongly bound or linked above iOS 15.0;
#   6. RunnerTests (XCTest, Xcode synchronized folder example/ios/RunnerTests) on an iOS simulator,
#      with -parallel-testing-enabled NO (8 GB machines: parallel clones exhaust memory);
#   7. the example host's integration_test suites on the same simulator, one `flutter test` per
#      file (FIX-CI-SUITES, from QA-03 / QA-11): engine_smoke (ENG-09), ios_preview (IOS-11),
#      QA-03's accuracy, av_sync and parity with --dart-define=QA03_MEDIA=<the ENG-05 fixtures>
#      (+ QA03_GOLDENS, the API-03 corpus; QA03_OUT under example/build/danaview_ios_suites), and
#      QA-11's conformance, preset_matrix and audio_mix. A failed file does not stop the others;
#      a per-file summary is printed and the script exits non-zero if any failed. Each log is kept
#      in example/build/danaview_ios_suites/<suite>.log. The media must be readable (the suites
#      skip without it), so a missing fixture tree is an error, not a skip;
#   8. optional (DANAVIEW_E2E=1): QA-00's app-level E2E suite (integration_test/editor) through
#      integration_test/editor/tool/e2e_host.sh on the same simulator. Off by default: QA-01
#      certifies it by hand (scripts/ci/editor/README.md), it needs the staged speech models and
#      takes hours.
#
# Usage:
#   scripts/ci/editor/ios.sh                    # everything
#   scripts/ci/editor/ios.sh --no-device-build  # skip 4-5 (simulator tests only)
#   scripts/ci/editor/ios.sh --no-sim-tests     # skip 6-8 (device build + D-41 check only)
#   scripts/ci/editor/ios.sh --smoke-only       # step 7 runs engine_smoke_test.dart only
#   scripts/ci/editor/ios.sh --runner-tests-only  # stop after step 6 (RunnerTests)
#   scripts/ci/editor/ios.sh --no-runner-tests    # skip step 6 (device build and step 7-8 only)
#
# Environment:
#   DANAVIEW_IOS_SIMULATOR          simulator name or UDID (default: the first available iPhone on
#                                the newest iOS runtime)
#   DANAVIEW_ALLOW_MISSING_CMAKE=1  local runs only: warn instead of failing when CMake >= 3.28 is
#                                missing, as long as the whisper xcframework script has not landed
#   DANAVIEW_IOS_SUITES          space-separated subset of step 7 (smoke ios_preview accuracy
#                                av_sync parity conformance preset_matrix audio_mix)
#   DANAVIEW_E2E=1               run step 8; DANAVIEW_E2E_MODELS_DIR (or DV_E2E_MODELS_DIR) names
#                                the folder with the tiny speech models for scenario 8, and
#                                DANAVIEW_E2E_TARGET picks the files (e2e_host.sh run target,
#                                default all)
#   DANAVIEW_IOS_ONLY_TESTING    xcodebuild -only-testing filter of step 6 (default RunnerTests;
#                                e.g. RunnerTests/ChannelRoundTripTests; comma-separated for several,
#                                e.g. RunnerTests/A,RunnerTests/B). Failure messages of step
#                                6 are printed from its result bundle (example/build/RunnerTests.xcresult)
#   DANAVIEW_IOS_SKIP_TESTING    xcodebuild -skip-testing filter of step 6 (comma-separated)
#   DANAVIEW_IOS_RUNNER_LANE     gate: step 6 skips every class of ios_device_lane_classes.txt;
#                                device: step 6 runs only those classes (docs/v1.2/CI_LANES.md);
#                                unset: every RunnerTests class (local runs)
#   DV_PERF_STRICT=1             absolute timing budgets (a quiet dev Mac): forwarded to RunnerTests
#                                as TEST_RUNNER_DV_PERF_STRICT (Support/PerfGate.swift) and to the
#                                step-7/8 suites as --dart-define=DV_PERF_STRICT=1
#   DANAVIEW_IOS_DRY_RUN=1       print the step-7/8 commands (and check the inputs) without a
#                                toolchain, a build or a simulator
set -euo pipefail

# Absolute timing budgets of the RunnerTests only with DV_PERF_STRICT=1 (xcodebuild hands
# TEST_RUNNER_<name> to the test process as <name>).
if [ "${DV_PERF_STRICT:-}" = 1 ]; then export TEST_RUNNER_DV_PERF_STRICT=1; fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CI_DIR="$ROOT/scripts/ci/editor"
EXAMPLE="$ROOT/packages/danaview_editor_engine/example"
WHISPER_SCRIPT="$ROOT/packages/danaview_whisper/tool/build_ios_xcframework.sh"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

MEDIA="$ROOT/packages/danaview_editor_engine/test_fixtures/media"
GOLDENS="$ROOT/packages/danaview_editor_engine_api/test_fixtures/images"
SUITE_OUT="$EXAMPLE/build/danaview_ios_suites"
E2E_HOST="$ROOT/integration_test/editor/tool/e2e_host.sh"
ALL_SUITES="smoke ios_preview accuracy av_sync parity conformance preset_matrix audio_mix"
DRY_RUN="${DANAVIEW_IOS_DRY_RUN:-}"

DEVICE_BUILD=true
SIM_TESTS=true
RUNNER_TESTS_ONLY=false
RUNNER_TESTS=true
SUITES="${DANAVIEW_IOS_SUITES:-$ALL_SUITES}"
for arg in "$@"; do
  case "$arg" in
    --no-device-build) DEVICE_BUILD=false ;;
    --no-sim-tests) SIM_TESTS=false ;;
    --smoke-only) SUITES=smoke ;;
    --runner-tests-only) RUNNER_TESTS_ONLY=true ;;
    --no-runner-tests) RUNNER_TESTS=false ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown argument $arg" >&2; exit 2 ;;
  esac
done

GHA="${GITHUB_ACTIONS:-}"
group() { if [ "$GHA" = true ]; then echo "::group::$1"; else echo "==> $1"; fi; }
endgroup() { if [ "$GHA" = true ]; then echo "::endgroup::"; fi; }
notice() { if [ "$GHA" = true ]; then echo "::notice title=ios::$1"; else echo "note: $1"; fi; }
warn() { if [ "$GHA" = true ]; then echo "::warning title=ios::$1"; else echo "warning: $1" >&2; fi; }
die() { if [ "$GHA" = true ]; then echo "::error title=ios::$1"; else echo "error: $1" >&2; fi; exit 1; }
fail_note() { if [ "$GHA" = true ]; then echo "::error title=ios::$1"; else echo "error: $1" >&2; fi; }

# version_ge A B: A >= B.
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, A, "."); nb = split(b, B, ".");
    for (i = 1; i <= 3; i++) { x = (i <= na) ? A[i] + 0 : 0; y = (i <= nb) ? B[i] + 0 : 0;
      if (x > y) exit 0; if (x < y) exit 1 }
    exit 0 }'
}

# --- Step 7 suite table ---------------------------------------------------------------------------
# suite_file <suite>: the example host's integration_test file.
suite_file() {
  case "$1" in
    smoke) echo engine_smoke_test.dart ;;
    *) echo "$1_test.dart" ;;
  esac
}

# suite_defines <suite>: one --dart-define per line (QA-03 reads the ENG-05 media from the host's
# disk; an iOS simulator reads host paths directly).
suite_defines() {
  if [ "${DV_PERF_STRICT:-}" = 1 ]; then echo "--dart-define=DV_PERF_STRICT=1"; fi
  case "$1" in
    accuracy | av_sync) echo "--dart-define=QA03_MEDIA=$MEDIA" ;;
    parity)
      echo "--dart-define=QA03_MEDIA=$MEDIA"
      echo "--dart-define=QA03_GOLDENS=$GOLDENS"
      echo "--dart-define=QA03_OUT=$SUITE_OUT/qa03_ios"
      # iOS vs Android parity when the Android renders are committed (QA-03 report).
      if [ -d "$ROOT/docs/v1.1/editor/qa/QA-03-parity/android" ]; then
        echo "--dart-define=QA03_PEER=$ROOT/docs/v1.1/editor/qa/QA-03-parity/android"
      fi
      ;;
  esac
}

# Validates $SUITES: known names, test files present, QA-03 media readable. Sets RUN_SUITES.
declare -a RUN_SUITES=()
check_suites() {
  local s f
  for s in $SUITES; do
    case " $ALL_SUITES " in *" $s "*) ;; *) die "DANAVIEW_IOS_SUITES: unknown suite $s (known: $ALL_SUITES)" ;; esac
    f="$(suite_file "$s")"
    if [ ! -f "$EXAMPLE/integration_test/$f" ]; then
      die "example/integration_test/$f is missing (suite $s)"
    fi
    case "$s" in
      accuracy | av_sync | parity)
        [ -f "$MEDIA/manifest.json" ] || die "ENG-05 media not found at ${MEDIA#"$ROOT"/} (QA-03 suites would only skip)"
        ;;
    esac
    if [ "$s" = parity ]; then
      [ -f "$GOLDENS/goldens.json" ] || die "API-03 golden corpus not found at ${GOLDENS#"$ROOT"/}"
    fi
    RUN_SUITES+=("$s")
  done
  [ "${#RUN_SUITES[@]}" -gt 0 ] || die "no integration_test suites selected"
}

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

e2e_command() {
  local models="${DANAVIEW_E2E_MODELS_DIR:-${DV_E2E_MODELS_DIR:-}}"
  local -a cmd=(bash "$E2E_HOST" -p ios -d "$1")
  if [ -n "$models" ]; then cmd+=(-m "$models"); fi
  cmd+=(run "${DANAVIEW_E2E_TARGET:-all}")
  printf '%s\n' "${cmd[@]}"
}

if [ "$DRY_RUN" = 1 ]; then
  echo "dry run (DANAVIEW_IOS_DRY_RUN=1): no toolchain, no build, no simulator; steps 1-6 not shown"
  check_suites
  for s in "${RUN_SUITES[@]}"; do
    declare -a D=()
    while IFS= read -r line; do [ -n "$line" ] && D+=("$line"); done < <(suite_defines "$s")
    echo "+ (cd ${EXAMPLE#"$ROOT"/} && flutter test integration_test/$(suite_file "$s") -d <udid>${D[*]+ ${D[*]}}) > ${SUITE_OUT#"$ROOT"/}/$s.log"
  done
  if [ "${DANAVIEW_E2E:-}" = 1 ]; then
    [ -f "$E2E_HOST" ] || die "DANAVIEW_E2E=1 but ${E2E_HOST#"$ROOT"/} is missing (QA-00)"
    echo "+ $(e2e_command '<udid>' | tr '\n' ' ')"
  fi
  echo "ios: dry run done"
  exit 0
fi
# Fail on a bad suite selection or missing media before the long builds.
if [ "$SIM_TESTS" = true ] && [ "$RUNNER_TESTS_ONLY" != true ]; then check_suites; fi

# Step 6's -only-testing / -skip-testing lists. The device-lane classes have one source of truth,
# ios_device_lane_classes.txt (docs/v1.2/CI_LANES.md).
LANE_FILE="$CI_DIR/ios_device_lane_classes.txt"
lane_classes() { grep -vE '^[[:space:]]*(#|$)' "$LANE_FILE" | sed 's/[[:space:]]//g' | paste -sd, -; }
ONLY_TESTING="${DANAVIEW_IOS_ONLY_TESTING:-RunnerTests}"
SKIP_TESTING="${DANAVIEW_IOS_SKIP_TESTING:-}"
case "${DANAVIEW_IOS_RUNNER_LANE:-}" in
  '') ;;
  gate) SKIP_TESTING="${SKIP_TESTING:+$SKIP_TESTING,}$(lane_classes)" ;;
  device)
    [ -z "${DANAVIEW_IOS_ONLY_TESTING:-}" ] || die "DANAVIEW_IOS_RUNNER_LANE=device sets the -only-testing list; unset DANAVIEW_IOS_ONLY_TESTING"
    ONLY_TESTING="$(lane_classes)"
    ;;
  *) die "DANAVIEW_IOS_RUNNER_LANE must be gate, device or unset (got ${DANAVIEW_IOS_RUNNER_LANE})" ;;
esac
if [ -n "${DANAVIEW_IOS_RUNNER_LANE:-}" ]; then
  [ -n "$(lane_classes)" ] || die "${LANE_FILE#"$ROOT"/} lists no classes"
fi

# --- 1. Toolchain -----------------------------------------------------------------------------
group "toolchain"
command -v xcodebuild >/dev/null || die "xcodebuild not found: install Xcode 26.6 (scripts/ci/editor/README.md)"
command -v flutter >/dev/null || die "flutter not found: install Flutter 3.44.2"
command -v pod >/dev/null || die "CocoaPods not found: brew install cocoapods"
xcodebuild -version | sed -n 1p
flutter --version | sed -n 1p

CMAKE_OK=false
for c in "$(command -v cmake || true)" /opt/homebrew/bin/cmake /usr/local/bin/cmake; do
  [ -n "$c" ] && [ -x "$c" ] || continue
  v="$("$c" --version | sed -n 1p | awk '{ print $3 }')"
  if version_ge "$v" 3.28; then
    CMAKE_OK=true
    echo "cmake $v ($c)"
    break
  fi
done
if [ "$CMAKE_OK" != true ]; then
  msg="CMake >= 3.28 is required to build WhisperCore.xcframework (AI-05). Install it with: brew install cmake"
  if [ "${DANAVIEW_ALLOW_MISSING_CMAKE:-}" = 1 ] && [ "$GHA" != true ] && [ ! -f "$WHISPER_SCRIPT" ]; then
    warn "$msg (continuing: DANAVIEW_ALLOW_MISSING_CMAKE=1 and the whisper xcframework script has not landed)"
  else
    die "$msg"
  fi
fi
endgroup

# --- 2. D-41 guard self-test --------------------------------------------------------------------
group "check_ios_min_os.sh --self-test"
bash "$CI_DIR/check_ios_min_os.sh" --self-test
endgroup

# --- 3. Whisper xcframework (AI-05) ---------------------------------------------------------------
if [ -f "$WHISPER_SCRIPT" ]; then
  group "whisper xcframework (build_ios_xcframework.sh --if-missing)"
  bash "$WHISPER_SCRIPT" --if-missing
  endgroup
else
  notice "packages/danaview_whisper/tool/build_ios_xcframework.sh does not exist yet (AI-05); WhisperCore.xcframework not built"
fi

group "flutter pub get (example)"
(cd "$EXAMPLE" && flutter pub get)
endgroup

# --- 4-5. Device build + D-41 check ------------------------------------------------------------------
if [ "$DEVICE_BUILD" = true ]; then
  group "flutter build ios --no-codesign (example, release)"
  (cd "$EXAMPLE" && flutter build ios --no-codesign --release)
  endgroup

  group "check_ios_min_os.sh (example app, engine pod, WhisperCore.xcframework)"
  declare -a CHECK=("$EXAMPLE/build/ios/iphoneos/Runner.app")
  pod="$EXAMPLE/build/ios/Release-iphoneos/danaview_editor_engine/danaview_editor_engine.framework"
  if [ -e "$pod" ]; then CHECK+=("$pod"); fi
  while IFS= read -r xc; do
    [ -n "$xc" ] && CHECK+=("$xc")
  done < <(find "$ROOT/packages/danaview_whisper" -type d -name 'WhisperCore.xcframework' -not -path '*/third_party/*' -prune 2>/dev/null)
  bash "$CI_DIR/check_ios_min_os.sh" "${CHECK[@]}"
  endgroup
fi

# --- 6-7. Simulator tests -------------------------------------------------------------------------
# Boots $UDID. `simctl bootstatus -b` can wait forever on an already booted device, so this polls
# the device state with a deadline instead.
boot_simulator() {
  xcrun simctl boot "$UDID" 2>/dev/null || true
  local booted=false
  for _ in $(seq 1 90); do
    if xcrun simctl list devices | grep -F "$UDID" | grep -q "(Booted)"; then booted=true; break; fi
    sleep 2
  done
  [ "$booted" = true ] || die "simulator $UDID did not boot within 180 s"
}

# Prints every test failure (test, message, source location) of the result bundle $1.
print_test_failures() {
  [ -d "$1" ] || { echo "no result bundle at $1"; return 0; }
  xcrun xcresulttool get test-results summary --path "$1" --format json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    print("xcresulttool printed no summary"); sys.exit(0)
fails = data.get("testFailures", [])
print("%d test failure(s):" % len(fails))
for f in fails:
    print("FAIL %s: %s" % (f.get("testIdentifierString") or f.get("testName"), f.get("failureText", "").strip()))
' || true
}

if [ "$SIM_TESTS" = true ]; then
  group "pick a simulator"
  SIM="${DANAVIEW_IOS_SIMULATOR:-}"
  UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
want = sys.argv[1]
data = json.load(sys.stdin)["devices"]
def ver(rt):
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    return (int(m.group(1)), int(m.group(2))) if m else None
best = None
for rt, devices in data.items():
    v = ver(rt)
    if v is None:
        continue
    for d in devices:
        if want and want in (d["udid"], d["name"]):
            print(d["udid"]); sys.exit(0)
        if not want and d["name"].startswith("iPhone") and (best is None or v > best[0]):
            best = (v, d["udid"])
if want:
    sys.exit(1)
if best:
    print(best[1])
' "$SIM")" || die "simulator '${SIM}' not found (xcrun simctl list devices available)"
  [ -n "$UDID" ] || die "no available iPhone simulator: install an iOS simulator runtime in Xcode"
  echo "simulator $UDID"
  boot_simulator
  endgroup

  if [ "$RUNNER_TESTS" = true ]; then
  group "RunnerTests (xcodebuild test)"
  (cd "$EXAMPLE" && flutter build ios --simulator --debug --config-only)
  # -quiet hides the assertion messages, so they are printed from the result bundle on failure.
  BUNDLE="$EXAMPLE/build/RunnerTests.xcresult"
  rm -rf "$BUNDLE"
  declare -a FILTER=()
  IFS=',' read -r -a ONLY_LIST <<< "$ONLY_TESTING"
  for t in "${ONLY_LIST[@]}"; do FILTER+=("-only-testing:$t"); done
  if [ -n "$SKIP_TESTING" ]; then
    IFS=',' read -r -a SKIP_LIST <<< "$SKIP_TESTING"
    for t in "${SKIP_LIST[@]}"; do FILTER+=("-skip-testing:$t"); done
  fi
  echo "xcodebuild test filter: ${FILTER[*]}"
  if ! (cd "$EXAMPLE/ios" && xcodebuild test \
    -workspace Runner.xcworkspace \
    -scheme Runner \
    -configuration Debug \
    -destination "id=$UDID" \
    "${FILTER[@]}" \
    -parallel-testing-enabled NO \
    -resultBundlePath "$BUNDLE" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet); then
    print_test_failures "$BUNDLE"
    die "RunnerTests failed (failure messages above; result bundle ${BUNDLE#"$ROOT"/})"
  fi
  endgroup
  else
    notice "RunnerTests not run (--no-runner-tests)"
  fi
  if [ "$RUNNER_TESTS_ONLY" = true ]; then
    echo "ios: OK (RunnerTests only)"
    exit 0
  fi

  # --- 7. integration_test suites (one flutter test per file; a failure does not stop the rest) ---
  rm -rf "$SUITE_OUT"
  mkdir -p "$SUITE_OUT"
  declare -a SUMMARY=()
  FAILED=0
  for s in "${RUN_SUITES[@]}"; do
    f="$(suite_file "$s")"
    declare -a D=()
    while IFS= read -r line; do [ -n "$line" ] && D+=("$line"); done < <(suite_defines "$s")
    logf="$SUITE_OUT/$s.log"
    group "integration_test/$f"
    # xcodebuild and an earlier suite may leave the simulator shut down.
    boot_simulator
    started=$SECONDS
    status=PASS
    if ! (cd "$EXAMPLE" && flutter test "integration_test/$f" -d "$UDID" ${D[@]+"${D[@]}"}) 2>&1 | tee "$logf"; then
      status=FAIL
    fi
    read -r passed failures skipped < <(progress_counts "$logf")
    if [ "$status" = FAIL ]; then
      FAILED=$((FAILED + 1))
      fail_note "integration_test/$f failed; log in ${logf#"$ROOT"/}"
    elif [ "$skipped" != "?" ] && [ "$skipped" -gt 0 ]; then
      warn "integration_test/$f skipped $skipped test(s); see ${logf#"$ROOT"/}"
    fi
    SUMMARY+=("$(printf '%-14s %-5s %6s %6s %7s %7ss' "$s" "$status" "$passed" "$failures" "$skipped" "$((SECONDS - started))")")
    endgroup
  done

  # --- 8. QA-00 E2E suite (opt-in) ---------------------------------------------------------------
  if [ "${DANAVIEW_E2E:-}" = 1 ]; then
    [ -f "$E2E_HOST" ] || die "DANAVIEW_E2E=1 but ${E2E_HOST#"$ROOT"/} is missing (QA-00)"
    group "QA-00 E2E suite (integration_test/editor via e2e_host.sh)"
    boot_simulator
    declare -a E2E=()
    while IFS= read -r line; do E2E+=("$line"); done < <(e2e_command "$UDID")
    started=$SECONDS
    status=PASS
    if ! "${E2E[@]}"; then
      status=FAIL
      FAILED=$((FAILED + 1))
      fail_note "QA-00 E2E suite failed; evidence in build/e2e/ios/$UDID/"
    fi
    SUMMARY+=("$(printf '%-14s %-5s %6s %6s %7s %7ss' e2e "$status" - - - "$((SECONDS - started))")")
    endgroup
  else
    notice "QA-00 E2E suite (integration_test/editor) not run: set DANAVIEW_E2E=1 (QA-01 certifies it by hand)"
  fi

  group "integration_test summary"
  printf '%-14s %-5s %6s %6s %7s %8s\n' suite result passed failed skipped time
  for row in "${SUMMARY[@]}"; do echo "$row"; done
  echo "logs in ${SUITE_OUT#"$ROOT"/}/<suite>.log"
  endgroup
  [ "$FAILED" -eq 0 ] || die "$FAILED integration_test suite(s) failed (see the summary above)"
fi

echo "ios: OK"
