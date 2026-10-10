#!/usr/bin/env bash
# OWNER: ENG-09
#
# ios CI job (ARCH §22, BUILD_PLAN ENG-09) on the self-hosted Mac (fallback macos-15):
#
#   1. toolchain: Xcode, Flutter, CocoaPods and CMake >= 3.28 (fails early with the
#      `brew install cmake` instruction; the whisper xcframework needs it, AI-05);
#   2. check_ios_min_os.sh --self-test (its negative and positive fixtures, D-41);
#   3. packages/vwish_whisper/tool/build_ios_xcframework.sh --if-missing, when that script exists;
#   4. `flutter build ios --no-codesign` of the engine example host (release, device);
#   5. check_ios_min_os.sh on the built Runner.app, the engine pod framework and
#      WhisperCore.xcframework (when built): nothing strongly bound or linked above iOS 15.0;
#   6. RunnerTests (XCTest, Xcode synchronized folder example/ios/RunnerTests) on an iOS simulator;
#   7. integration_test/engine_smoke_test.dart on the same simulator.
#
# Usage:
#   scripts/ci/editor/ios.sh                    # everything
#   scripts/ci/editor/ios.sh --no-device-build  # skip 4-5 (simulator tests only)
#   scripts/ci/editor/ios.sh --no-sim-tests     # skip 6-7 (device build + D-41 check only)
#
# Environment:
#   VWISH_IOS_SIMULATOR          simulator name or UDID (default: the first available iPhone on
#                                the newest iOS runtime)
#   VWISH_ALLOW_MISSING_CMAKE=1  local runs only: warn instead of failing when CMake >= 3.28 is
#                                missing, as long as the whisper xcframework script has not landed
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CI_DIR="$ROOT/scripts/ci/editor"
EXAMPLE="$ROOT/packages/vwish_editor_engine/example"
WHISPER_SCRIPT="$ROOT/packages/vwish_whisper/tool/build_ios_xcframework.sh"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

DEVICE_BUILD=true
SIM_TESTS=true
for arg in "$@"; do
  case "$arg" in
    --no-device-build) DEVICE_BUILD=false ;;
    --no-sim-tests) SIM_TESTS=false ;;
    -h | --help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument $arg" >&2; exit 2 ;;
  esac
done

GHA="${GITHUB_ACTIONS:-}"
group() { if [ "$GHA" = true ]; then echo "::group::$1"; else echo "==> $1"; fi; }
endgroup() { if [ "$GHA" = true ]; then echo "::endgroup::"; fi; }
notice() { if [ "$GHA" = true ]; then echo "::notice title=ios::$1"; else echo "note: $1"; fi; }
warn() { if [ "$GHA" = true ]; then echo "::warning title=ios::$1"; else echo "warning: $1" >&2; fi; }
die() { if [ "$GHA" = true ]; then echo "::error title=ios::$1"; else echo "error: $1" >&2; fi; exit 1; }

# version_ge A B: A >= B.
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, A, "."); nb = split(b, B, ".");
    for (i = 1; i <= 3; i++) { x = (i <= na) ? A[i] + 0 : 0; y = (i <= nb) ? B[i] + 0 : 0;
      if (x > y) exit 0; if (x < y) exit 1 }
    exit 0 }'
}

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
  if [ "${VWISH_ALLOW_MISSING_CMAKE:-}" = 1 ] && [ "$GHA" != true ] && [ ! -f "$WHISPER_SCRIPT" ]; then
    warn "$msg (continuing: VWISH_ALLOW_MISSING_CMAKE=1 and the whisper xcframework script has not landed)"
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
  notice "packages/vwish_whisper/tool/build_ios_xcframework.sh does not exist yet (AI-05); WhisperCore.xcframework not built"
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
  for pod in "$EXAMPLE"/build/ios/Release-iphoneos/vwish_editor_engine/vwish_editor_engine.framework; do
    [ -e "$pod" ] && CHECK+=("$pod")
  done
  while IFS= read -r xc; do
    [ -n "$xc" ] && CHECK+=("$xc")
  done < <(find "$ROOT/packages/vwish_whisper" -type d -name 'WhisperCore.xcframework' -not -path '*/third_party/*' -prune 2>/dev/null)
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

if [ "$SIM_TESTS" = true ]; then
  group "pick a simulator"
  SIM="${VWISH_IOS_SIMULATOR:-}"
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

  group "RunnerTests (xcodebuild test)"
  (cd "$EXAMPLE" && flutter build ios --simulator --debug --config-only)
  (cd "$EXAMPLE/ios" && xcodebuild test \
    -workspace Runner.xcworkspace \
    -scheme Runner \
    -configuration Debug \
    -destination "id=$UDID" \
    -only-testing:RunnerTests \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO \
    -quiet)
  endgroup

  group "integration_test/engine_smoke_test.dart"
  # xcodebuild may shut the simulator down after testing.
  boot_simulator
  (cd "$EXAMPLE" && flutter test integration_test/engine_smoke_test.dart -d "$UDID")
  endgroup
fi

echo "ios: OK"
