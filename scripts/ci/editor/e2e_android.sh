#!/usr/bin/env bash
# OWNER: QA-02
#
# Runs the shared E2E suite (integration_test/editor, QA-00, ARCH §21.2) on an Android emulator or
# device, in small batches (BUILD_PLAN QA-02). Run by hand on a machine with the Android emulators:
#
#   scripts/ci/editor/e2e_android.sh                         # Pixel_9_Pro_XL_API_35, every batch
#   scripts/ci/editor/e2e_android.sh Pixel_API_34            # another AVD (booted when not running)
#   scripts/ci/editor/e2e_android.sh emulator-5554           # an already running emulator/device
#   DANAVIEW_E2E_ONLY="s01 s07 x_android_export_background" scripts/ci/editor/e2e_android.sh
#   DANAVIEW_E2E_DRY_RUN=1 scripts/ci/editor/e2e_android.sh  # print the batches and commands only
#
# What it does:
#   1. picks the device: a serial that adb lists, a running emulator of that AVD, or boots the AVD
#      headless (-no-window -no-boot-anim -no-snapshot-save, plus -no-audio unless
#      DANAVIEW_E2E_AUDIO=1; an API 29 AVD also gets -feature GLESDynamicVersion) and waits for
#      sys.boot_completed;
#   2. on API 30+ creates the app's shared folders (Android/data/<app>/files/e2e_*) and opens the
#      shell-owned ones to the app (see prepare_shared), then integration_test/editor/tool/
#      e2e_host.sh stage (fixtures), and stage-models when DANAVIEW_E2E_MODELS is set;
#   3. runs the suite in batches, one flutter invocation sequence per batch, so one crash or hang
#      cannot sink the rest: each scenario file is a batch (`e2e_host.sh run sNN`, which runs the
#      phases of s09 in order), and the Android extra's phase pairs are separate batches
#      (x_android_export_background:fgs = fgs + fgs-check, :cancel, :swipe = swipe + swipe-check,
#      :death = death + death-check), served by `e2e_host.sh serve`. A failed batch does not stop
#      the run. Each batch has a timeout (DANAVIEW_E2E_BATCH_TIMEOUT) after which its process tree is
#      killed and the batch counts as TIMEOUT. Every adb call the script makes itself is bounded. An
#      emulator that stops answering is booted again from its AVD (at most 3 times) and restaged
#      before the next batch; the batch it died in is marked with * in the summary;
#   4. prints a per-batch summary (batch, result, time, log) and exits non-zero if any batch failed
#      or timed out.
#
# Batches by device: API >= 29 runs s01..s18 and the x_android_export_background phase pairs;
# API < 29 (below the editor gate) runs only x_android_api28. s08 needs the speech models
# (DANAVIEW_E2E_MODELS); without them it is reported PENDING and does not fail the run.
#
# Evidence: build/e2e/android/<serial>/ (e2e_host.sh's logs/, screens/, files/), plus per batch
# logs/batch-<batch>.log (the host driver's output) and logs/batch-<batch>.logcat.txt, and
# summary.txt.
#
# Environment:
#   DANAVIEW_E2E_ONLY="s01 s07 x_android_export_background"  only these batches (an extra's name
#                       selects all of its phase pairs; x_android_export_background:cancel one pair)
#   DANAVIEW_E2E_SKIP="s08 s13"  leave these batches out (same names)
#   DANAVIEW_E2E_DRY_RUN=1  print the device plan, batches and commands; no device, no build
#   DANAVIEW_E2E_AUDIO=1    boot the emulator with audio and turn the host microphone on
#                           (`adb emu avd hostmicon`), for s13's recording
#   DANAVIEW_E2E_MODELS=<dir>  ggml-tiny-q5_1.bin + ggml-silero-v6.2.0.bin for s08 (staged with
#                           `e2e_host.sh stage-models`; DANAVIEW_E2E_MODELS_DIR is an alias)
#   DANAVIEW_E2E_BATCH_TIMEOUT=<s>  per batch (default 2400)
#   DANAVIEW_E2E_PHASE_TIMEOUT=<s>  per flutter run (default 1200; e2e_host.sh's DV_E2E_PHASE_TIMEOUT)
#   DANAVIEW_E2E_KEEP_APP=0  let `flutter test` uninstall the app after each run (default 1: the
#                           app stays installed so the staged fixtures under Android/data/<app>/files
#                           and a phase's saved state survive into the next run)
#   DANAVIEW_E2E_KEEP_EMULATOR=1  leave an emulator this script booted running at the end
#   DANAVIEW_E2E_EMULATOR_ARGS  extra emulator arguments when booting
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SUITE="integration_test/editor"
HOST="$ROOT/$SUITE/tool/e2e_host.sh"
TARGET="${1:-Pixel_9_Pro_XL_API_35}"
DRY_RUN="${DANAVIEW_E2E_DRY_RUN:-}"
AUDIO="${DANAVIEW_E2E_AUDIO:-}"
MODELS_DIR="${DANAVIEW_E2E_MODELS:-${DANAVIEW_E2E_MODELS_DIR:-}}"
BATCH_TIMEOUT="${DANAVIEW_E2E_BATCH_TIMEOUT:-2400}"
PHASE_TIMEOUT="${DANAVIEW_E2E_PHASE_TIMEOUT:-1200}"
KEEP_APP="${DANAVIEW_E2E_KEEP_APP:-1}"
EXTRA_PAIRS="fgs cancel swipe death"

GHA="${GITHUB_ACTIONS:-}"
group() { if [ "$GHA" = true ]; then echo "::group::$1"; else echo "==> $1"; fi; }
endgroup() { if [ "$GHA" = true ]; then echo "::endgroup::"; fi; }
die() { if [ "$GHA" = true ]; then echo "::error title=e2e-android::$1"; else echo "error: $1" >&2; fi; exit 1; }
note() { if [ "$GHA" = true ]; then echo "::notice title=e2e-android::$1"; else echo "note: $1"; fi; }

case "$TARGET" in
  -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
esac
[ $# -le 1 ] || { echo "usage: $0 [<avd>|<serial>]" >&2; exit 2; }
[ -f "$HOST" ] || die "the QA-00 host driver ${HOST#"$ROOT"/} is missing"

WINDOWS=""
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) WINDOWS=1 ;; esac
if [ -n "$WINDOWS" ]; then
  # Git Bash rewrites arguments that start with / into Windows paths; the host driver passes device
  # paths (/sdcard/...) to adb.exe, which must stay as they are.
  export MSYS2_ARG_CONV_EXCL="/sdcard;/storage;/data/local"
fi

# ---- process helpers ----------------------------------------------------------------------------

# Kills <pid> and everything it started. On Windows the flutter tool (cmd + dart.exe) and adb are
# native processes a bash `kill` does not reach, so the Windows process tree goes with taskkill.
kill_tree() {
  local pid="$1" child
  if [ -n "$WINDOWS" ]; then
    local winpid
    winpid="$(cat "/proc/$pid/winpid" 2>/dev/null || true)"
    if [ -n "$winpid" ]; then taskkill //F //T //PID "$winpid" >/dev/null 2>&1 || true; fi
  else
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$child"; done
  fi
  kill "$pid" 2>/dev/null || true
}

# Windows only: flutter tool processes left behind for this device (a phase whose app was killed can
# leave its `flutter test` waiting). They would otherwise stop or reinstall the app under the next
# batch.
kill_stray_flutter() {
  [ -n "$WINDOWS" ] || return 0
  [ -n "${SERIAL:-}" ] || return 0
  powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='dart.exe'\" | Where-Object { \$_.CommandLine -match 'flutter_tools' -and \$_.CommandLine -match 'integration_test' -and \$_.CommandLine -match '$SERIAL' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Output \"killed stray flutter tool \$(\$_.ProcessId)\" }" 2>/dev/null | tr -d '\r' || true
}

# Runs "$@" in the background, waits at most <seconds>; returns its status, or 124 after a timeout.
run_with_timeout() {
  local limit="$1" pid start status=0
  shift
  "$@" &
  pid=$!
  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$limit" ]; then
      echo "[e2e_android] timeout after ${limit}s: killing $1" >&2
      kill_tree "$pid"
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 2
  done
  wait "$pid" || status=$?
  return $status
}

# ---- device -------------------------------------------------------------------------------------

ADB=""
EMULATOR=""
EMU_AVD=""
BOOTED_BY_US=""
SERIAL=""

find_tools() {
  ADB="$(command -v adb || true)"
  local sdk
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    [ -n "$sdk" ] || continue
    if [ -z "$ADB" ] && [ -x "$sdk/platform-tools/adb" ]; then ADB="$sdk/platform-tools/adb"; fi
    if [ -z "$EMULATOR" ] && [ -x "$sdk/emulator/emulator" ]; then EMULATOR="$sdk/emulator/emulator"; fi
    if [ -z "$EMULATOR" ] && [ -x "$sdk/emulator/emulator.exe" ]; then EMULATOR="$sdk/emulator/emulator.exe"; fi
  done
  [ -n "$ADB" ] || die "adb not found: install the Android SDK platform-tools and set ANDROID_HOME"
  command -v flutter >/dev/null || die "flutter not found: install Flutter 3.44.2"
}

device_serials() { "$ADB" devices | tr -d '\r' | awk 'NR > 1 && $2 == "device" { print $1 }'; }

avd_target() { # <avd>: android-NN from ~/.android/avd/<avd>.ini
  local ini="${ANDROID_AVD_HOME:-$HOME/.android/avd}/$1.ini"
  [ -f "$ini" ] && sed -nE 's/^target=//p' "$ini" | tr -d '\r' | head -1
  return 0
}

emulator_args() { # <avd>
  local a="-avd $1 -no-window -no-boot-anim -no-snapshot-save"
  [ "$AUDIO" = 1 ] || a="$a -no-audio"
  case "$(avd_target "$1")" in android-29) a="$a -feature GLESDynamicVersion" ;; esac
  echo "$a ${DANAVIEW_E2E_EMULATOR_ARGS:-}"
}

wait_booted() {
  run_with_timeout 300 "$ADB" -s "$SERIAL" wait-for-device || die "$SERIAL did not come up within 300 s"
  local _
  for _ in $(seq 1 180); do
    [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && return 0
    sleep 2
  done
  die "$SERIAL did not finish booting"
}

pick_device() {
  local s
  for s in $(device_serials); do
    if [ "$s" = "$TARGET" ]; then SERIAL="$s"; return 0; fi
  done
  case "$TARGET" in emulator-* | *:*) die "device $TARGET is not attached (adb devices)" ;; esac
  # A running emulator of that AVD?
  for s in $(device_serials); do
    case "$s" in emulator-*) ;; *) continue ;; esac
    if [ "$("$ADB" -s "$s" emu avd name 2>/dev/null | tr -d '\r' | head -1)" = "$TARGET" ]; then SERIAL="$s"; return 0; fi
  done
  [ -n "$EMULATOR" ] || die "emulator not found under ANDROID_HOME; cannot boot $TARGET"
  [ -n "$(avd_target "$TARGET")" ] || die "no AVD named $TARGET (avdmanager list avd)"
  local port=5554
  while device_serials | grep -qx "emulator-$port"; do port=$((port + 2)); done
  SERIAL="emulator-$port"
  boot_avd "$TARGET"
  BOOTED_BY_US=1
}

boot_avd() { # <avd>: boots it headless on $SERIAL's port and waits for sys.boot_completed
  local port="${SERIAL#emulator-}"
  echo "booting $1 as $SERIAL: emulator $(emulator_args "$1") -port $port"
  # shellcheck disable=SC2046
  nohup "$EMULATOR" $(emulator_args "$1") -port "$port" >> "$ROOT/build/e2e_android_emulator_$port.log" 2>&1 < /dev/null &
  wait_booted
}

# Whether the device answers (bounded: a dead emulator can leave adb waiting forever).
device_ok() {
  [ "$(run_with_timeout 30 "$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '
')" = 1 ]
}

# Before a batch: an emulator that died (it happens under long exports on this host) is booted
# again from its AVD and restaged, so the remaining batches still run. Returns 1 when the device is
# gone and cannot be brought back.
RESTARTS=0
ensure_device() {
  device_ok && return 0
  echo "[e2e_android] $SERIAL does not answer"
  if [ -z "$EMU_AVD" ] || [ -z "$EMULATOR" ] || [ "$RESTARTS" -ge 3 ]; then return 1; fi
  RESTARTS=$((RESTARTS + 1))
  run_with_timeout 30 "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
  run_with_timeout 30 "$ADB" kill-server >/dev/null 2>&1 || true
  boot_avd "$EMU_AVD"
  BOOTED_BY_US=1
  setup_device
}

# Microphone, shared folders and staging (after the first boot and after a restart).
setup_device() {
  if [ "$AUDIO" = 1 ]; then
    if run_with_timeout 30 "$ADB" -s "$SERIAL" emu avd hostmicon >/dev/null 2>&1; then echo "host microphone: on (adb emu avd hostmicon)"
    else note "could not turn the host microphone on (not an emulator?)"; fi
  fi
  prepare_shared
  host stage || die "e2e_host.sh stage failed"
  if [ -n "$MODELS_DIR" ]; then host stage-models "$MODELS_DIR" || die "e2e_host.sh stage-models failed"; fi
}

# The app's external files folder (the handshake's shared dir). On API 30+ a folder that adb creates
# under Android/data/<app> belongs to the shell user (mode 2770), and the app can neither enter nor
# create it: only the app's own getExternalFilesDir() has vold create it for the app, and the suite
# never calls that. So, before staging, the folders the suite uses (files/, e2e_fixtures,
# e2e_models, e2e_handshake, e2e_out) are created here and every one the shell owns is opened to
# the app (2777). adb push writes files as 0666, which the app can read. API 29 (sdcardfs) derives
# the owner from the path and needs none of this.
prepare_shared() {
  local base="/sdcard/Android/data/com.vecvel.danaview" d dirs
  [ "$API" -ge 30 ] || return 0
  dirs="$base $base/files $base/files/e2e_fixtures $base/files/e2e_models $base/files/e2e_handshake $base/files/e2e_out"
  "$ADB" -s "$SERIAL" shell "mkdir -p $dirs" || die "cannot create $base/files on $SERIAL"
  for d in $dirs; do
    if [ "$("$ADB" -s "$SERIAL" shell stat -c %u "$d" | tr -d '\r')" = 2000 ]; then
      "$ADB" -s "$SERIAL" shell chmod 2777 "$d" || die "cannot open $d to the app"
    fi
  done
  echo "shared dir: $("$ADB" -s "$SERIAL" shell ls -lan "$base/files" | tr -d '\r' | awk 'NR > 1 { printf "%s %s %s; ", $1, $3, $NF }')"
}

# ---- batches ------------------------------------------------------------------------------------

API=""
declare -a BATCHES=()

all_batches() {
  local f n
  if [ -n "$API" ] && [ "$API" -lt 29 ]; then echo x_android_api28; return; fi
  for f in "$ROOT/$SUITE"/s[0-9][0-9]_*_test.dart; do n="$(basename "$f")"; echo "${n%%_*}"; done
  for n in $EXTRA_PAIRS; do echo "x_android_export_background:$n"; done
}

selected() { # <batch> <list>: whether the list names the batch or its file
  local b="$1" t
  for t in $2; do
    if [ "$t" = "$b" ] || [ "$t" = "${b%%:*}" ]; then return 0; fi
  done
  return 1
}

check_names() { # <var name> <list>
  local t ok b
  for t in $2; do
    ok=""
    for b in $(all_batches) x_android_api28; do
      if [ "$t" = "$b" ] || [ "$t" = "${b%%:*}" ]; then ok=1; fi
    done
    [ -n "$ok" ] || die "$1: unknown batch $t (batches: $(all_batches | tr '\n' ' '))"
  done
}

# ---- one batch ----------------------------------------------------------------------------------

OUT=""
host() { DV_E2E_PHASE_TIMEOUT="$PHASE_TIMEOUT" bash "$HOST" -p android -d "$SERIAL" "$@"; }

# One phase of x_android_export_background, served by `e2e_host.sh serve`. <expect> is "pass" or
# "dies" (the host carried out an action that ended the app).
extra_phase() {
  local phase="$1" expect="$2" file="$SUITE/x_android_export_background_test.dart"
  local logf="$OUT/logs/x_android_export_background_test-$phase.log" fpid spid fstatus=0 sstatus=0 start died=""
  echo "[e2e_android] flutter test $file phase=$phase (expect $expect), log ${logf#"$ROOT"/}"
  host serve >> "$OUT/logs/host-serve.log" 2>&1 &
  spid=$!
  (cd "$ROOT" && flutter test "$file" -d "$SERIAL" --dart-define=DANAVIEW_EDITOR=true \
    --dart-define=DANAVIEW_AUTO_CAPTIONS=true --dart-define=DV_E2E_HOST=true \
    --dart-define=DV_E2E_PHASE="$phase") > "$logf" 2>&1 &
  fpid=$!
  start=$SECONDS
  fgs_seen=""
  while kill -0 "$fpid" 2>/dev/null; do
    # Records the export service's foreground type once it runs (mediaProcessing on API 35,
    # dataSync on API 34, none on API 29).
    if [ -z "$fgs_seen" ] && [ $(((SECONDS - start) % 5)) -eq 0 ]; then
      fgs_seen="$(fgs_probe)"
      if [ -n "$fgs_seen" ]; then echo "[e2e_android] DV_E2E_FGS phase=$phase API=$API $fgs_seen" | tee -a "$logf"; fi
    fi
    # `serve` returns (status 3) a minute after an action that ended the app.
    if [ -z "$died" ] && ! kill -0 "$spid" 2>/dev/null; then
      wait "$spid" || sstatus=$?
      died=1
      [ "$sstatus" -eq 3 ] && echo "[e2e_android] phase $phase: the host ended the app"
      sleep 5
      kill_tree "$fpid"
      break
    fi
    if [ $((SECONDS - start)) -ge "$PHASE_TIMEOUT" ]; then
      echo "[e2e_android] TIMEOUT phase $phase after ${PHASE_TIMEOUT}s" | tee -a "$logf"
      kill_tree "$fpid"
      fstatus=124
      break
    fi
    sleep 1
  done
  if [ "$fstatus" -ne 124 ]; then wait "$fpid" 2>/dev/null || fstatus=$?; fi
  if [ -z "$died" ]; then
    kill_tree "$spid"
    wait "$spid" 2>/dev/null || true
  fi
  kill_stray_flutter
  if [ "$expect" = dies ]; then
    if [ "$sstatus" -eq 3 ]; then echo "[e2e_android] PASS phase $phase (ended the app as expected)"; return 0; fi
    echo "[e2e_android] FAIL phase $phase: expected the host to end the app (flutter status $fstatus)"
    return 1
  fi
  if [ "$fstatus" -eq 0 ] && ! grep -q 'Some tests failed\|\[E\]' "$logf"; then
    echo "[e2e_android] PASS phase $phase"
    return 0
  fi
  echo "[e2e_android] FAIL phase $phase (status $fstatus)"
  return 1
}

# The export service's foreground state, from dumpsys (empty while it is not in the foreground).
fgs_probe() {
  "$ADB" -s "$SERIAL" shell dumpsys activity services com.vecvel.danaview 2>/dev/null | tr -d '\r' |
    grep -E 'isForeground=true|foregroundServiceType=|ServiceRecord' | tr -s ' ' | tr '\n' ' ' |
    grep 'isForeground=true' || true
}

run_batch() { # <batch>
  local b="$1"
  case "$b" in
    x_android_export_background:fgs) extra_phase fgs dies && extra_phase fgs-check pass ;;
    x_android_export_background:cancel) extra_phase cancel pass ;;
    x_android_export_background:swipe) extra_phase swipe dies && extra_phase swipe-check pass ;;
    x_android_export_background:death) extra_phase death dies && extra_phase death-check pass ;;
    *) host run "$b" ;;
  esac
}

print_cmd() { # <batch>: the dry-run view of run_batch
  local b="$1" ph
  case "$b" in
    x_android_export_background:*)
      case "${b#*:}" in fgs) ph="fgs fgs-check" ;; swipe) ph="swipe swipe-check" ;; death) ph="death death-check" ;; *) ph="${b#*:}" ;; esac
      for p in $ph; do
        echo "  + $SUITE/tool/e2e_host.sh -p android -d $SERIAL serve &"
        echo "  + flutter test $SUITE/x_android_export_background_test.dart -d $SERIAL --dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true --dart-define=DV_E2E_HOST=true --dart-define=DV_E2E_PHASE=$p"
      done ;;
    *) echo "  + DV_E2E_PHASE_TIMEOUT=$PHASE_TIMEOUT $SUITE/tool/e2e_host.sh -p android -d $SERIAL run $b" ;;
  esac
}

# ---- main ---------------------------------------------------------------------------------------

group "device"
if [ "$DRY_RUN" = 1 ]; then
  SERIAL="$TARGET"
  case "$TARGET" in emulator-* | *:*) ;; *)
    SERIAL="<serial of $TARGET>"
    echo "would boot (when not running): emulator $(emulator_args "$TARGET") -port <free port>" ;;
  esac
  API="${DANAVIEW_E2E_DRY_RUN_API:-35}"
  echo "dry run (DANAVIEW_E2E_DRY_RUN=1): no device, no build; assuming API $API"
else
  find_tools
  pick_device
  API="$("$ADB" -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')"
  echo "device $SERIAL, API $API, $("$ADB" -s "$SERIAL" shell getprop ro.product.cpu.abi | tr -d '\r')$([ -n "$BOOTED_BY_US" ] && echo ", booted by this script")"
  case "$SERIAL" in emulator-*) EMU_AVD="$(run_with_timeout 30 "$ADB" -s "$SERIAL" emu avd name 2>/dev/null | tr -d '
' | head -1)" ;; esac
  [ -z "$EMU_AVD" ] || echo "emulator AVD: $EMU_AVD (booted again from it if it dies mid-run)"
fi
endgroup

check_names DANAVIEW_E2E_ONLY "${DANAVIEW_E2E_ONLY:-}"
check_names DANAVIEW_E2E_SKIP "${DANAVIEW_E2E_SKIP:-}"
declare -a PENDING=()
for b in $(all_batches); do
  if [ -n "${DANAVIEW_E2E_ONLY:-}" ] && ! selected "$b" "$DANAVIEW_E2E_ONLY"; then continue; fi
  if [ -n "${DANAVIEW_E2E_SKIP:-}" ] && selected "$b" "$DANAVIEW_E2E_SKIP"; then continue; fi
  if [ "$b" = s08 ] && [ -z "$MODELS_DIR" ]; then PENDING+=("$b"); continue; fi
  BATCHES+=("$b")
done
# DANAVIEW_E2E_ONLY may name the below-gate extra on any device.
if [ -n "${DANAVIEW_E2E_ONLY:-}" ] && selected x_android_api28 "$DANAVIEW_E2E_ONLY" && [ "${API:-35}" -ge 29 ]; then
  note "x_android_api28 only checks something below API 29; on API $API its test is skipped"
  BATCHES+=(x_android_api28)
fi
[ "${#BATCHES[@]}" -gt 0 ] || [ "${#PENDING[@]}" -gt 0 ] || die "no batches selected"

OUT="$ROOT/build/e2e/android/$SERIAL"
if [ "$DRY_RUN" = 1 ]; then
  group "batches (dry run)"
  echo "  + (API >= 30) adb shell mkdir -p + chmod 2777 Android/data/com.vecvel.danaview/files/{,e2e_fixtures,e2e_models,e2e_handshake,e2e_out}"
  echo "  + $SUITE/tool/e2e_host.sh -p android -d $SERIAL stage"
  [ -z "$MODELS_DIR" ] || echo "  + $SUITE/tool/e2e_host.sh -p android -d $SERIAL stage-models <DANAVIEW_E2E_MODELS>"
  [ "$KEEP_APP" != 1 ] || echo "  (flutter test runs with --no-uninstall: DANAVIEW_E2E_KEEP_APP=1)"
  for b in ${BATCHES[@]+"${BATCHES[@]}"}; do echo "batch $b (timeout ${BATCH_TIMEOUT}s)"; print_cmd "$b"; done
  for b in ${PENDING[@]+"${PENDING[@]}"}; do echo "batch $b PENDING: speech models not staged (DANAVIEW_E2E_MODELS)"; done
  endgroup
  echo "e2e-android: dry run done"
  exit 0
fi

mkdir -p "$OUT/logs"
if [ "$KEEP_APP" = 1 ]; then
  # `flutter test` uninstalls an integration test app when it ends, which deletes the staged fixtures
  # (Android/data/<app>/files) and the state a later phase reads. A wrapper adds --no-uninstall.
  REAL_FLUTTER="$(command -v flutter)"
  SHIM="$OUT/flutter_shim"
  mkdir -p "$SHIM"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = test ]; then shift; exec "$DANAVIEW_E2E_REAL_FLUTTER" test --no-uninstall "$@"; fi' \
    'exec "$DANAVIEW_E2E_REAL_FLUTTER" "$@"' > "$SHIM/flutter"
  chmod +x "$SHIM/flutter"
  export DANAVIEW_E2E_REAL_FLUTTER="$REAL_FLUTTER"
  export PATH="$SHIM:$PATH"
fi

group "stage"
setup_device
endgroup

declare -a SUMMARY=()
FAILED=0
for b in ${BATCHES[@]+"${BATCHES[@]}"}; do
  label="$(echo "$b" | tr ':' '-')"
  blog="$OUT/logs/batch-$label.log"
  group "batch $b"
  if ! ensure_device; then
    FAILED=$((FAILED + 1))
    echo "error: batch $b not run: $SERIAL is gone and could not be booted again" >&2
    SUMMARY+=("$(printf '%-36s %-8s %6s   %s' "$b" NODEVICE - "$SERIAL lost")")
    endgroup
    continue
  fi
  run_with_timeout 30 "$ADB" -s "$SERIAL" logcat -c 2>/dev/null || true
  : > "$OUT/logs/batch-$label.log.start"
  started=$SECONDS
  status=PASS
  rc=0
  run_with_timeout "$BATCH_TIMEOUT" run_batch "$b" > "$blog" 2>&1 || rc=$?
  if [ "$rc" -eq 124 ]; then status=TIMEOUT; elif [ "$rc" -ne 0 ]; then status=FAIL; fi
  kill_stray_flutter >> "$blog" 2>&1
  run_with_timeout 120 "$ADB" -s "$SERIAL" logcat -d > "$OUT/logs/batch-$label.logcat.txt" 2>/dev/null || true
  if ! device_ok; then
    echo "[e2e_android] $SERIAL stopped answering during batch $b (emulator died)" >> "$blog"
    [ "$status" = PASS ] || status="$status*"
  fi
  elapsed=$((SECONDS - started))
  # Measured values of this batch (DV_E2E_REPORT / DV_E2E_EXPORT lines of its flutter logs).
  for f in "$OUT/logs/${b%%:*}"_*.log; do
    [ -f "$f" ] && [ "$(find "$f" -newer "$OUT/logs/batch-$label.log.start" 2>/dev/null)" ] && grep -h 'DV_E2E_REPORT\|DV_E2E_EXPORT' "$f" | sed 's/^/  /' || true
  done
  rm -f "$OUT/logs/batch-$label.log.start"
  tail -n 5 "$blog"
  if [ "$status" != PASS ]; then
    FAILED=$((FAILED + 1))
    if [ "$GHA" = true ]; then echo "::error title=e2e-android::batch $b $status"; else echo "error: batch $b $status (log ${blog#"$ROOT"/})" >&2; fi
  fi
  SUMMARY+=("$(printf '%-36s %-8s %6ss  %s' "$b" "$status" "$elapsed" "${blog#"$ROOT"/}")")
  endgroup
done
for b in ${PENDING[@]+"${PENDING[@]}"}; do
  SUMMARY+=("$(printf '%-36s %-8s %6s   %s' "$b" PENDING - "speech models not staged (DANAVIEW_E2E_MODELS)")")
done

run_with_timeout 300 bash "$HOST" -p android -d "$SERIAL" collect >/dev/null 2>&1 || true

group "summary ($SERIAL, API $API)"
{
  printf '%-36s %-8s %7s  %s\n' batch result time log
  for line in ${SUMMARY[@]+"${SUMMARY[@]}"}; do echo "$line"; done
  echo "${#BATCHES[@]} batches run, $FAILED failed or timed out, ${#PENDING[@]} pending, emulator restarts: $RESTARTS"
  echo "(a result with * means the emulator died during that batch; NODEVICE: not run, device lost)"
} | tee "$OUT/summary.txt"
echo "evidence: ${OUT#"$ROOT"/}/ (logs/, screens/, files/, summary.txt)"
endgroup

if [ -n "$BOOTED_BY_US" ] && [ "${DANAVIEW_E2E_KEEP_EMULATOR:-}" != 1 ]; then
  run_with_timeout 30 "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
fi

[ "$FAILED" -eq 0 ] || die "$FAILED of ${#BATCHES[@]} batches failed (see the summary above)"
echo "e2e-android: OK"
