#!/usr/bin/env bash
# OWNER: QA-01
#
# Runs and certifies QA-00's app-level E2E suite (integration_test/editor, ARCH §21.2) on the iOS
# Simulator (BUILD_PLAN QA-01). Run it by hand on the self-hosted Mac; it takes about an hour per
# full lane. It:
#
#   1. checks the toolchain (Xcode, Flutter, xcrun simctl);
#   2. builds WhisperCore.xcframework when missing or stale
#      (packages/danaview_whisper/tool/build_ios_xcframework.sh --if-missing; scenario 8 needs it);
#   3. per lane: finds the simulator by name and runtime, boots it when it is shut down, and waits
#      for the boot to finish;
#   4. stages the fixtures and the speech models (integration_test/editor/tool/e2e_host.sh stage /
#      stage-models; on the simulator both are read in place, never copied into the repo);
#   5. runs the lane's files through e2e_host.sh, which passes --dart-define=DANAVIEW_EDITOR=true
#      --dart-define=DANAVIEW_AUTO_CAPTIONS=true, serves the handshake and collects logs,
#      screenshots and exported files into build/e2e/ios/<udid>/;
#   6. writes a per-file summary (build/e2e/ios/<udid>/summary.txt) and shuts down every simulator
#      it booted (8 GB machines: one simulator at a time).
#
# Lanes (ARCH §21.2, QA-01 spec):
#   iphone   the whole suite on the iPhone (iOS 26 runtime)                         target: all
#   ipad     scenario 12 on the iPad Pro (keyboard and pointer; the physical hardware keyboard and
#            the Files/Photos drops are the README's manual checklist)              target: s12
#   legacy   scenarios 1-3 on the iOS 18.2 runtime                                  target: s01 s02 s03
#   lab      the iPhone 7 (iOS 15.8) / iPhone 8 (iOS 16.7) device smoke (launch, player, s01-s04).
#            Needs DV_E2E_LAB_UDIDS (connected devices); without it the lane is recorded as
#            "deferred: no device available" (owner default 2026-10-08, ARCH D-43).
#
# Usage:
#   scripts/ci/editor/e2e_ios.sh                     iphone, ipad, legacy, lab (in that order)
#   scripts/ci/editor/e2e_ios.sh iphone legacy       only these lanes
#   scripts/ci/editor/e2e_ios.sh --target s08 iphone one scenario (or sNN, x_name, a file path, all)
#   scripts/ci/editor/e2e_ios.sh --dry-run           print the plan (devices, commands), run nothing
#
# Environment:
#   DV_E2E_IPHONE            iPhone simulator name or UDID     (default "iPhone 17 Pro")
#   DV_E2E_IPHONE_RUNTIME    its runtime                        (default: the newest "iOS 26.x")
#   DV_E2E_IPAD              iPad simulator name or UDID        (default: the first "iPad Pro" on it)
#   DV_E2E_LEGACY            legacy-lane simulator              (default: same name as the iPhone,
#                                                               else the first iPhone on the runtime)
#   DV_E2E_LEGACY_RUNTIME    legacy runtime                     (default "iOS 18.2")
#   DV_E2E_MODELS / DV_E2E_MODELS_DIR
#                            folder with ggml-tiny-q5_1.bin and ggml-silero-v6.2.0.bin
#                            (default ~/danaview-models). Missing: scenario 8 fails, nothing is
#                            downloaded.
#   DV_E2E_LAB_UDIDS         space-separated UDIDs of connected iPhone 7 / iPhone 8 devices
#   DV_E2E_KEEP_BOOTED=1     leave the simulators this script booted running
#   DV_E2E_SKIP_WHISPER=1    skip step 2 (the framework is already up to date)
#   DV_E2E_SKIP_PODS=1       skip the `pod install` that keeps ios/Pods in step with the plugin sources
#   DV_E2E_EXTRA_DEFINES     extra "KEY=VALUE" defines passed to e2e_host.sh -D (space-separated),
#                            e.g. DV_E2E_NO_WORKAROUNDS=true
#   DV_E2E_PHASE_TIMEOUT     per-phase watchdog in seconds (e2e_host.sh; default 900)
#
# Exit status: 0 when every lane that ran passed, 1 otherwise. Simulator realities (no hardware HEVC,
# software H.264, meaningless performance, no BG GPU) are reported by the suite as DV_E2E_REPORT
# lines, not failed. bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOST="$ROOT/integration_test/editor/tool/e2e_host.sh"
WHISPER="$ROOT/packages/danaview_whisper/tool/build_ios_xcframework.sh"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

IPHONE="${DV_E2E_IPHONE:-iPhone 17 Pro}"
IPHONE_RUNTIME="${DV_E2E_IPHONE_RUNTIME:-}"
IPAD="${DV_E2E_IPAD:-}"
LEGACY="${DV_E2E_LEGACY:-}"
LEGACY_RUNTIME="${DV_E2E_LEGACY_RUNTIME:-iOS 18.2}"
MODELS="${DV_E2E_MODELS:-${DV_E2E_MODELS_DIR:-$HOME/danaview-models}}"
TARGET=""
DRY=0
LANES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,54p' "$0"; exit 0 ;;
    iphone|ipad|legacy|lab) LANES+=("$1"); shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ ${#LANES[@]} -gt 0 ] || LANES=(iphone ipad legacy lab)

say() { echo "[e2e_ios $(date +%H:%M:%S)] $*" >&2; }
die() { say "ERROR: $*"; exit 1; }

BOOTED_BY_US=()
cleanup() {
  [ "${DV_E2E_KEEP_BOOTED:-0}" = 1 ] && return 0
  local u
  for u in ${BOOTED_BY_US[@]+"${BOOTED_BY_US[@]}"}; do
    say "shutting down $u (booted by this script)"
    xcrun simctl shutdown "$u" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# ---- devices ------------------------------------------------------------------------------------

# Prints "<runtime>|<name>|<udid>|<state>" for every available simulator.
sim_rows() {
  xcrun simctl list devices available | awk '
    /^-- / { rt = $0; sub(/^-- /, "", rt); sub(/ --$/, "", rt); next }
    /\([0-9A-F-]{36}\)/ {
      line = $0; sub(/^ +/, "", line)
      match(line, /\([0-9A-F-]{36}\)/); udid = substr(line, RSTART + 1, RLENGTH - 2)
      name = substr(line, 1, RSTART - 2)
      st = line; sub(/.*\(/, "", st); sub(/\).*/, "", st)
      print rt "|" name "|" udid "|" st
    }'
}

newest_ios26() { sim_rows | cut -d'|' -f1 | grep '^iOS 26' | sort -t. -k2,2n | tail -1; }

# find_sim <name-or-udid> <runtime> [fallback name prefix] -> udid
find_sim() {
  local want="$1" rt="$2" prefix="${3:-}" row
  if echo "$want" | grep -Eq '^[0-9A-F-]{36}$'; then echo "$want"; return 0; fi
  row="$(sim_rows | awk -F'|' -v rt="$rt" -v n="$want" '$1 == rt && $2 == n' | head -1)"
  if [ -z "$row" ] && [ -n "$prefix" ]; then
    row="$(sim_rows | awk -F'|' -v rt="$rt" -v p="$prefix" '$1 == rt && index($2, p) == 1' | head -1)"
  fi
  [ -n "$row" ] || return 1
  echo "$row" | cut -d'|' -f3
}

sim_label() { sim_rows | awk -F'|' -v u="$1" '$3 == u { print $2 " (" $1 ")" }' | head -1; }

boot() {
  local u="$1" st
  st="$(sim_rows | awk -F'|' -v u="$u" '$3 == u { print $4 }' | head -1)"
  if [ "$st" != "Booted" ]; then
    say "booting $(sim_label "$u") $u"
    xcrun simctl boot "$u"
    BOOTED_BY_US+=("$u")
  fi
  xcrun simctl bootstatus "$u" -b >/dev/null
}

shutdown_if_ours() {
  [ "${DV_E2E_KEEP_BOOTED:-0}" = 1 ] && return 0
  local u="$1" keep=() b
  for b in ${BOOTED_BY_US[@]+"${BOOTED_BY_US[@]}"}; do
    if [ "$b" = "$u" ]; then xcrun simctl shutdown "$u" >/dev/null 2>&1 || true; say "shut down $u"
    else keep+=("$b"); fi
  done
  BOOTED_BY_US=(${keep[@]+"${keep[@]}"})
}

# ---- running ------------------------------------------------------------------------------------

host_defines() {
  local d
  for d in ${DV_E2E_EXTRA_DEFINES:-}; do printf -- '-D\n%s\n' "$d"; done
}

# summarize <udid> <label> <lane> <since-line>: per-file PASS/FAIL from the host log, new lines only.
summarize() {
  local u="$1" label="$2" lane="$3" from="$4" out="$ROOT/build/e2e/ios/$1"
  {
    echo "QA-01 lane $lane on $label ($u), $(date '+%Y-%m-%d %H:%M')"
    tail -n +"$from" "$out/logs/host.log" |
      sed -nE 's/.*(PASS|FAIL|TIMEOUT) integration_test\/editor\/([a-z0-9_]+)\.dart ?(.*)/\1 \2 \3/p; s/.*(skip [a-z0-9_]+ on ios).*/SKIP \1/p; s/.*phase ([a-z-]+) ended the app as expected.*/PASS phase \1 (ended by the host as expected)/p; s/.*phase ([a-z-]+) was expected to end the app.*/FAIL phase \1 (did not end the app)/p'
    grep -h 'DV_E2E_REPORT' "$out"/logs/*.log 2>/dev/null | sed 's/^.*DV_E2E_REPORT/REPORT/' | sort -u || true
  } | tee -a "$out/summary.txt"
}

# run_lane <lane> <udid> <targets...>
run_lane() {
  local lane="$1" u="$2"; shift 2
  local label from rc=0 t args=()
  label="$(sim_label "$u")"
  while IFS= read -r t; do [ -n "$t" ] && args+=("$t"); done < <(host_defines)
  if [ "$DRY" = 1 ]; then
    for t in "$@"; do
      echo "$HOST -p ios -d $u -m $MODELS ${args[*]-} run $t    # $lane: $label"
    done
    return 0
  fi
  boot "$u"
  mkdir -p "$ROOT/build/e2e/ios/$u/logs"
  touch "$ROOT/build/e2e/ios/$u/logs/host.log"
  from=$(( $(wc -l < "$ROOT/build/e2e/ios/$u/logs/host.log") + 1 ))
  "$HOST" -p ios -d "$u" stage
  if [ -f "$MODELS/ggml-tiny-q5_1.bin" ] && [ -f "$MODELS/ggml-silero-v6.2.0.bin" ]; then
    "$HOST" -p ios -d "$u" stage-models "$MODELS"
  else
    say "speech models not found in $MODELS: scenario 8 will fail (nothing is downloaded)"
  fi
  for t in "$@"; do
    "$HOST" -p ios -d "$u" -m "$MODELS" ${args[@]+"${args[@]}"} run "$t" || rc=1
  done
  summarize "$u" "$label" "$lane" "$from"
  shutdown_if_ours "$u"
  return $rc
}

# ---- main ---------------------------------------------------------------------------------------

if [ "$DRY" = 0 ]; then
  command -v xcrun >/dev/null || die "xcrun not found: install Xcode"
  command -v flutter >/dev/null || die "flutter not found on PATH"
  say "$(xcodebuild -version | tr '\n' ' ')"
  say "$(flutter --version 2>/dev/null | head -1)"
  if [ "${DV_E2E_SKIP_WHISPER:-0}" != 1 ] && [ -x "$WHISPER" ]; then
    say "WhisperCore.xcframework: $("$WHISPER" --status || true)"
    # The Android SDK's CMake 3.22 + Ninja is verified for this build (AI-05) when no newer one exists.
    if ! command -v cmake >/dev/null 2>&1; then export DV_ALLOW_OLD_CMAKE="${DV_ALLOW_OLD_CMAKE:-1}"; fi
    if ! "$WHISPER" --if-missing --jobs "${DV_E2E_WHISPER_JOBS:-2}"; then
      # A stale-but-present framework still runs the suite; a missing one cannot.
      [ "$("$WHISPER" --status || true)" = missing ] && die "WhisperCore.xcframework could not be built"
      say "WARNING: the WhisperCore.xcframework rebuild failed; continuing with the existing (stale) framework"
    fi
  fi
  # `flutter test` re-runs CocoaPods only when the Podfile or the plugin list changes, so a Swift
  # file added to a plugin pod (e.g. the engine's ios/Classes) is missing from Pods.xcodeproj and
  # the build fails with "Cannot find type ... in scope". Regenerate the Pods project first.
  if [ "${DV_E2E_SKIP_PODS:-0}" != 1 ] && [ -f "$ROOT/ios/Podfile" ]; then
    say "pod install (ios/)"
    (cd "$ROOT" && flutter pub get >/dev/null && cd ios && pod install >/dev/null) || die "pod install failed"
  fi
fi

[ -n "$IPHONE_RUNTIME" ] || IPHONE_RUNTIME="$(newest_ios26)"
[ -n "$IPHONE_RUNTIME" ] || die "no iOS 26 simulator runtime installed"

failed=0
for lane in "${LANES[@]}"; do
  case "$lane" in
    iphone)
      u="$(find_sim "$IPHONE" "$IPHONE_RUNTIME" "iPhone")" || die "no '$IPHONE' on $IPHONE_RUNTIME"
      run_lane iphone "$u" ${TARGET:-all} || failed=1 ;;
    ipad)
      u="$(find_sim "${IPAD:-iPad Pro}" "$IPHONE_RUNTIME" "iPad Pro")" || die "no iPad Pro on $IPHONE_RUNTIME"
      run_lane ipad "$u" ${TARGET:-s12} || failed=1 ;;
    legacy)
      if ! u="$(find_sim "${LEGACY:-$IPHONE}" "$LEGACY_RUNTIME" "iPhone")"; then
        say "legacy lane: no simulator on $LEGACY_RUNTIME (install it in Xcode > Settings > Components)"
        failed=1; continue
      fi
      if [ -n "$TARGET" ]; then run_lane legacy "$u" "$TARGET" || failed=1
      else run_lane legacy "$u" s01 s02 s03 || failed=1; fi ;;
    lab)
      if [ -z "${DV_E2E_LAB_UDIDS:-}" ]; then
        say "lab lane (iPhone 7 iOS 15.8, iPhone 8 iOS 16.7): deferred: no device available"
        continue
      fi
      for u in $DV_E2E_LAB_UDIDS; do
        # A device has no simctl handshake and cannot read the Mac's fixtures in place: the smoke
        # runs s01 (launch, Home, Projects) directly; s02-s04 need the fixtures in the app's
        # Documents/e2e_fixtures (copy them with Xcode > Devices > the app's container first).
        for t in s01 s02 s03 s04; do
          f="$(ls "$ROOT/integration_test/editor/${t}"_*_test.dart)"
          if [ "$DRY" = 1 ]; then echo "flutter test $f -d $u --dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true"; continue; fi
          mkdir -p "$ROOT/build/e2e/ios/$u/logs"
          (cd "$ROOT" && flutter test "$f" -d "$u" --dart-define=DANAVIEW_EDITOR=true \
              --dart-define=DANAVIEW_AUTO_CAPTIONS=true) > "$ROOT/build/e2e/ios/$u/logs/$t.log" 2>&1 \
            && say "lab $u PASS $t" || { say "lab $u FAIL $t"; failed=1; }
        done
      done ;;
  esac
done

say "done: $([ $failed = 0 ] && echo 'every lane passed' || echo 'failures, see build/e2e/ios/<udid>/summary.txt')"
exit $failed
