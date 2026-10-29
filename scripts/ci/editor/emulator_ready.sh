#!/usr/bin/env bash
# OWNER: ENG-09
#
# Android emulator readiness for the android-emulator CI job (CI round 5). Sourced by
# android_emulator.sh, or run on its own as the first command of the emulator-runner `script:`.
#
# - emulator_wait [timeout s]: `adb wait-for-device` (bounded), then polls sys.boot_completed and
#   the package manager until both answer; returns non-zero on timeout.
# - emulator_relaunch: kills the emulator of $ANDROID_SERIAL (adb emu kill, then the qemu process of
#   the AVD) and starts the AVD again headless with $DANAVIEW_EMULATOR_OPTIONS from the job's booted
#   AVD snapshot (the emulator cold-boots on its own when the snapshot does not load; a cold boot
#   cost the CI run minutes of boot and a busy system for the batches after it), never saving a
#   snapshot, waits for the boot and turns animations off. Needs DANAVIEW_EMULATOR_AVD
#   (the emulator-runner AVD name, `test`); at most DANAVIEW_EMULATOR_RELAUNCHES (default 3) per
#   run, logs in $DANAVIEW_EMULATOR_LOG_DIR (default /tmp).
# - emulator_ensure: emulator_wait (60 s) when the device is not answering, then one relaunch.
#
# Run on its own (`bash emulator_ready.sh`): waits for the first boot (DANAVIEW_EMULATOR_BOOT_TIMEOUT,
# default 300 s) and relaunches the emulator once when it does not come up.
#
# Environment: ANDROID_SERIAL (default emulator-5554), ANDROID_HOME / ANDROID_SDK_ROOT.

EMU_SERIAL="${ANDROID_SERIAL:-emulator-5554}"
EMU_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
EMU_ADB="$(command -v adb || true)"
[ -z "$EMU_ADB" ] && [ -n "$EMU_SDK" ] && EMU_ADB="$EMU_SDK/platform-tools/adb"
EMU_RELAUNCHES=0

emulator_log() { echo "emulator_ready: $*"; }

emulator_booted() {
  [ "$("$EMU_ADB" -s "$EMU_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] &&
    "$EMU_ADB" -s "$EMU_SERIAL" shell pm path android >/dev/null 2>&1
}

emulator_wait() {
  local timeout="${1:-300}" deadline
  deadline=$((SECONDS + timeout))
  timeout "$timeout" "$EMU_ADB" -s "$EMU_SERIAL" wait-for-device 2>/dev/null || true
  while [ "$SECONDS" -lt "$deadline" ]; do
    if emulator_booted; then
      emulator_log "$EMU_SERIAL booted"
      return 0
    fi
    sleep 3
  done
  emulator_log "$EMU_SERIAL did not finish booting within ${timeout} s"
  return 1
}

emulator_relaunch() {
  local avd="${DANAVIEW_EMULATOR_AVD:-}" max="${DANAVIEW_EMULATOR_RELAUNCHES:-3}" port log
  if [ -z "$avd" ] || [ -z "$EMU_SDK" ] || [ ! -x "$EMU_SDK/emulator/emulator" ]; then
    emulator_log "cannot relaunch (DANAVIEW_EMULATOR_AVD or the SDK emulator is missing)"
    return 1
  fi
  if [ "$EMU_RELAUNCHES" -ge "$max" ]; then
    emulator_log "relaunch budget ($max) used up"
    return 1
  fi
  EMU_RELAUNCHES=$((EMU_RELAUNCHES + 1))
  port="${EMU_SERIAL#emulator-}"
  log="${DANAVIEW_EMULATOR_LOG_DIR:-/tmp}/emulator-relaunch-$EMU_RELAUNCHES.log"
  emulator_log "relaunching $avd on port $port ($EMU_RELAUNCHES of $max); log $log"
  "$EMU_ADB" -s "$EMU_SERIAL" emu kill >/dev/null 2>&1 || true
  sleep 5
  pkill -f "qemu-system.*-avd $avd" 2>/dev/null || true
  sleep 2
  "$EMU_ADB" kill-server >/dev/null 2>&1 || true
  "$EMU_ADB" start-server >/dev/null 2>&1 || true
  # shellcheck disable=SC2086 # options are a word list
  nohup "$EMU_SDK/emulator/emulator" -port "$port" -avd "$avd" -no-snapshot-save \
    ${DANAVIEW_EMULATOR_OPTIONS:-} >"$log" 2>&1 &
  if ! emulator_wait "${DANAVIEW_EMULATOR_BOOT_TIMEOUT:-300}"; then
    tail -n 40 "$log" 2>/dev/null || true
    return 1
  fi
  for k in window_animation_scale transition_animation_scale animator_duration_scale; do
    "$EMU_ADB" -s "$EMU_SERIAL" shell settings put global "$k" 0.0 >/dev/null 2>&1 || true
  done
  "$EMU_ADB" -s "$EMU_SERIAL" shell input keyevent 82 >/dev/null 2>&1 || true
}

emulator_ensure() {
  emulator_booted && return 0
  emulator_log "$EMU_SERIAL is not answering"
  emulator_wait 60 && return 0
  emulator_relaunch
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  [ -n "$EMU_ADB" ] || { echo "emulator_ready: adb not found" >&2; exit 1; }
  if emulator_wait "${DANAVIEW_EMULATOR_BOOT_TIMEOUT:-300}"; then exit 0; fi
  # One retry of the boot.
  emulator_relaunch || exit 1
fi
