#!/usr/bin/env bash
# OWNER: QA-00
#
# Host driver of the shared E2E suite (integration_test/editor, ARCH §21.2). It stages the test media,
# runs one scenario file (all of its phases) with the right --dart-defines, and serves the file
# handshake the in-app test uses for what an app cannot do to itself (background/foreground, kill,
# permission grants, recents, notification actions, evidence screenshots).
# QA-01 (scripts/ci/editor/e2e_ios.sh) and QA-02 call it; it also runs by hand:
#
#   integration_test/editor/tool/e2e_host.sh -p ios -d <udid> stage
#   integration_test/editor/tool/e2e_host.sh -p ios -d <udid> run s07
#   integration_test/editor/tool/e2e_host.sh -p android -d emulator-5554 stage-models ~/models
#   integration_test/editor/tool/e2e_host.sh -p android -d emulator-5554 run all
#
# DV_E2E_PHASE_TIMEOUT=<seconds> (default 900) stops a phase that hangs and counts it as failed.
#
# Platforms: macOS (iOS Simulator, xcrun simctl) and macOS / Linux / Git Bash on Windows (Android
# Emulator, adb). Evidence lands in build/e2e/<platform>/<device>/ (logs, screenshots, exported files).

set -euo pipefail

APP_ID="com.vecvel.danaview"
ANDROID_ACTIVITY="$APP_ID/.MainActivity"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SUITE="integration_test/editor"
FIXTURES="$ROOT/packages/danaview_editor_engine/test_fixtures/media"
MODEL_FILES=("ggml-tiny-q5_1.bin" "ggml-silero-v6.2.0.bin")

PLATFORM=""
DEVICE=""
MODELS_DIR="${DV_E2E_MODELS_DIR:-}"
EXTRA_DEFINES=()

usage() {
  sed -n '2,20p' "$0"
  echo "commands: stage | stage-models <dir> | run <sNN|xname|file|all> | collect | serve"
  exit 2
}

while getopts "p:d:m:D:h" opt; do
  case "$opt" in
    p) PLATFORM="$OPTARG" ;;
    d) DEVICE="$OPTARG" ;;
    m) MODELS_DIR="$OPTARG" ;;
    D) EXTRA_DEFINES+=("--dart-define=$OPTARG") ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[[ -n "$PLATFORM" && -n "$DEVICE" && $# -ge 1 ]] || usage
CMD="$1"; shift

OUT="$ROOT/build/e2e/$PLATFORM/$DEVICE"
mkdir -p "$OUT/screens" "$OUT/logs" "$OUT/files"
log() { echo "[e2e_host $(date +%H:%M:%S)] $*" | tee -a "$OUT/logs/host.log" >&2; }

# ---- device file access -------------------------------------------------------------------------

ANDROID_SHARED="/sdcard/Android/data/$APP_ID/files"

ios_shared() {
  local data
  data="$(xcrun simctl get_app_container "$DEVICE" "$APP_ID" data 2>/dev/null || true)"
  if [[ -n "$data" ]]; then echo "$data/Documents"; fi
  return 0
}

# Lists request files (names only).
list_requests() {
  if [[ "$PLATFORM" == ios ]]; then
    local d; d="$(ios_shared)"; [[ -n "$d" && -d "$d/e2e_handshake" ]] || return 0
    (cd "$d/e2e_handshake" && ls req-*.json 2>/dev/null) || true
  else
    adb -s "$DEVICE" shell "ls $ANDROID_SHARED/e2e_handshake/ 2>/dev/null" | tr -d '\r' | grep '^req-.*\.json$' || true
  fi
}

read_shared() { # <relative path>
  if [[ "$PLATFORM" == ios ]]; then cat "$(ios_shared)/$1"; else adb -s "$DEVICE" shell "cat $ANDROID_SHARED/$1" | tr -d '\r'; fi
}

write_shared() { # <relative path> <contents>  (atomic: tmp + rename)
  if [[ "$PLATFORM" == ios ]]; then
    local d; d="$(ios_shared)"
    printf '%s' "$2" > "$d/$1.tmp" && mv "$d/$1.tmp" "$d/$1"
  else
    local tmp; tmp="$(mktemp)"; printf '%s' "$2" > "$tmp"
    adb -s "$DEVICE" push "$tmp" "$ANDROID_SHARED/$1.tmp" >/dev/null
    adb -s "$DEVICE" shell "mv $ANDROID_SHARED/$1.tmp $ANDROID_SHARED/$1"
    rm -f "$tmp"
  fi
}

# ---- actions ------------------------------------------------------------------------------------

app_foreground() {
  if [[ "$PLATFORM" == ios ]]; then xcrun simctl launch "$DEVICE" "$APP_ID" >/dev/null
  else adb -s "$DEVICE" shell am start -n "$ANDROID_ACTIVITY" >/dev/null; fi
}

app_background() {
  if [[ "$PLATFORM" == ios ]]; then xcrun simctl launch "$DEVICE" com.apple.Preferences >/dev/null
  else adb -s "$DEVICE" shell input keyevent KEYCODE_HOME; fi
}

app_kill() {
  if [[ "$PLATFORM" == ios ]]; then
    xcrun simctl terminate "$DEVICE" "$APP_ID" || true
  else
    local pid; pid="$(adb -s "$DEVICE" shell pidof "$APP_ID" | tr -d '\r')"
    if [[ -n "$pid" ]]; then adb -s "$DEVICE" shell run-as "$APP_ID" kill -9 "$pid" || adb -s "$DEVICE" shell am force-stop "$APP_ID"; fi
  fi
}

# Android 13+ asks for POST_NOTIFICATIONS on the first export of a fresh install; nobody answers that
# dialog in a test run, so the export would wait at "Preparing…". iOS needs nothing (no-op).
grant_notifications() {
  if [[ "$PLATFORM" == ios ]]; then return 0; fi
  adb -s "$DEVICE" shell pm grant "$APP_ID" android.permission.POST_NOTIFICATIONS
}

grant_mic() {
  if [[ "$PLATFORM" == ios ]]; then xcrun simctl privacy "$DEVICE" grant microphone "$APP_ID"
  else adb -s "$DEVICE" shell pm grant "$APP_ID" android.permission.RECORD_AUDIO; fi
}

android_tap_text() { # <text>: taps the first node with that text (uiautomator)
  # `uiautomator dump` fails ("could not get idle state") while a notification keeps updating, so a
  # failed or empty dump is retried a few times before giving up.
  local xml="" bounds attempt
  for attempt in 1 2 3 4 5; do
    if adb -s "$DEVICE" shell uiautomator dump /sdcard/e2e_ui.xml 2>&1 | tr -d '\r' | grep -q 'dumped to'; then
      xml="$(adb -s "$DEVICE" shell cat /sdcard/e2e_ui.xml | tr -d '\r')"
      bounds="$(echo "$xml" | tr '>' '\n' | grep -i "text=\"$1\"" | head -1 | sed -E 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1 \2 \3 \4/')"
      if [[ -n "$bounds" && "$bounds" != *"<"* ]]; then
        read -r x1 y1 x2 y2 <<< "$bounds"
        adb -s "$DEVICE" shell input tap $(((x1 + x2) / 2)) $(((y1 + y2) / 2))
        return 0
      fi
    fi
    log "uiautomator: no \"$1\" yet (attempt $attempt)"
    sleep 1
  done
  return 1
}

# Export job ids the app's engine has on record (ActiveExportStore's export-jobs.json, read with
# run-as; the test build is debuggable), else the ids the engine logged. One per line.
android_export_job_ids() {
  local f ids=""
  f="$(adb -s "$DEVICE" shell "run-as $APP_ID find . -name export-jobs.json 2>/dev/null" | tr -d '\r' | head -1)"
  if [[ -n "$f" ]]; then
    ids="$(adb -s "$DEVICE" shell "run-as $APP_ID cat $f" 2>/dev/null | tr -d '\r' | grep -oE '"id" *: *"ex_[^"]+"' | sed -E 's/.*"(ex_[^"]+)"/\1/' || true)"
  fi
  if [[ -z "$ids" ]]; then
    ids="$(adb -s "$DEVICE" logcat -d 2>/dev/null | tr -d '\r' | grep -oE 'ex_[A-Za-z0-9_-]+' | tail -5 || true)"
  fi
  printf '%s\n' "$ids" | awk 'NF && !seen[$0]++'
}

# Sends the export notification's Cancel action directly: the same intent its PendingIntent holds
# (ExportService ACTION_CANCEL + EXTRA_JOB_ID, AND-12 ExportNotification.cancelIntent). The service is
# not exported, so the plain shell is refused unless adb runs as root; it is retried through `su 0`
# (emulator userdebug images) and run-as (as the app).
# Returns 0 when at least one start was accepted.
android_send_export_cancel() {
  local svc="$APP_ID/com.vecvel.danaview.editor.engine.export.ExportService"
  local act="com.vecvel.danaview.editor.engine.export.CANCEL" id out sent=1
  for id in $(android_export_job_ids); do
    for prefix in "" "su 0" "run-as $APP_ID"; do
      out="$(adb -s "$DEVICE" shell "$prefix am startservice -n $svc -a $act --es jobId $id" 2>&1 | tr -d '\r')"
      if [[ "$out" != *Error* && "$out" != *Exception* && "$out" == *Starting* ]]; then
        log "cancel sent for $id${prefix:+ ($prefix)}"; sent=0; break
      fi
      log "cancel for $id${prefix:+ ($prefix)} refused: $(echo "$out" | tail -1)"
    done
  done
  return $sent
}

# Whether the app has any ActivityRecord (any state, finishing included) in the activity manager.
android_has_activity() {
  adb -s "$DEVICE" shell dumpsys activity activities | tr -d '\r' | grep -qE "ActivityRecord\{[^}]* $APP_ID/"
}

# Whether the app has a task in recents.
android_has_recent_task() {
  adb -s "$DEVICE" shell dumpsys activity recents | tr -d '\r' | grep -E 'Recent #|Task\{' | grep -qE "[ :=]$APP_ID([ /}]|$)"
}

# Whether the top resumed activity is the app's.
android_app_resumed() {
  adb -s "$DEVICE" shell dumpsys activity activities | tr -d '\r' | grep -E 'topResumedActivity|mResumedActivity|ResumedActivity:' | head -1 | grep -q "$APP_ID/"
}

# Swipes the app's task away in recents: opens recents and waits until it is on screen (the app is
# no longer resumed), swipes the centered card up, and repeats until `dumpsys activity recents` no
# longer lists the task. Returns 0 only when the task is confirmed gone.
# The app's task id from `dumpsys activity recents` ("Recent #n: Task{… #<id> type=standard … I=<app>/…}").
android_app_task_id() {
  adb -s "$DEVICE" shell dumpsys activity recents | tr -d '\r' | grep -E 'Recent #[0-9]+: Task\{' |
    grep -E "[ :=]$APP_ID([ /}]|$)" | head -1 | sed -nE 's/.*Task\{[^ ]+ #([0-9]+) .*/\1/p'
}

# Removes the app's own task from recents, as a user swipe would (AND-12 detached export).
# FIX M-21 (QA-02, 2026-10-17): swiping at the screen centre could remove ANOTHER app's task first
# (Photos, Settings), and the app's task went only after the export had finished attached. So the
# app's task is removed by id with `am stack remove <id>`, which goes through the same
# ActivityTaskManager.removeTask path as the launcher's swipe (checked on the API 35 image). The
# result is confirmed with `dumpsys activity recents` before reporting success. If `am stack remove`
# is unavailable, the gesture is the fallback, and every attempt checks WHICH task vanished, failing
# instead of reporting "task gone" when it was not the app's.
android_swipe_from_recents() {
  local id attempt size w h before after
  id="$(android_app_task_id)"
  if [[ -z "$id" ]]; then log "swipeFromRecents: the app has no task in recents"; return 1; fi
  for attempt in 1 2 3; do
    adb -s "$DEVICE" shell am stack remove "$id" >/dev/null 2>&1
    for _ in $(seq 1 10); do android_has_recent_task || break; sleep 0.3; done
    if ! android_has_recent_task; then
      log "swipeFromRecents: task $id removed by id (attempt $attempt)"; return 0
    fi
    log "swipeFromRecents: task $id still in recents after removal attempt $attempt"
    id="$(android_app_task_id)"; [[ -n "$id" ]] || { log "swipeFromRecents: task gone"; return 0; }
  done
  # Fallback: the launcher gesture, checking which task vanished.
  size="$(adb -s "$DEVICE" shell wm size | tr -d '\r' | awk '{print $NF}' | tail -1)"
  w="${size%x*}"; h="${size#*x}"
  for attempt in 1 2; do
    before="$(android_app_task_id)"
    adb -s "$DEVICE" shell input keyevent KEYCODE_APP_SWITCH
    for _ in $(seq 1 20); do android_app_resumed || break; sleep 0.5; done
    sleep 1.5
    adb -s "$DEVICE" shell input swipe $((w / 2)) $((h / 2)) $((w / 2)) $((h / 20)) 250
    for _ in $(seq 1 10); do android_has_recent_task || break; sleep 0.5; done
    adb -s "$DEVICE" shell input keyevent KEYCODE_HOME
    after="$(android_app_task_id)"
    if [[ -n "$before" && -z "$after" ]]; then
      log "swipeFromRecents: task $before gone by gesture (fallback attempt $attempt)"; return 0
    fi
    log "swipeFromRecents: the gesture did not remove the app's task (fallback attempt $attempt; before=$before after=$after)"
  done
  return 1
}

# Destroys the activity for real while the process lives on (AND-12 detached export): the host asks
# the in-app test to finish its activity (`do-<seq>-<action>.json`, which E2eHandshake.requestAndDie
# answers with SystemNavigator.pop(), i.e. Activity.finish()), then waits until `dumpsys activity
# activities` has no ActivityRecord of the app. Returns 0 only when that is confirmed.
android_destroy_activity() { # <seq> <action>
  local seq="$1" action="$2" attempt
  for attempt in 1 2 3; do
    write_shared "e2e_handshake/do-$seq-$action.json" "{\"seq\":$seq,\"do\":\"finishActivity\",\"attempt\":$attempt}"
    for _ in $(seq 1 30); do android_has_activity || break; sleep 0.5; done
    if ! android_has_activity; then log "destroyActivity: no ActivityRecord left (attempt $attempt)"; return 0; fi
    log "destroyActivity: activity still recorded after attempt $attempt"
  done
  return 1
}

screenshot() { # <name>
  local f; f="$OUT/screens/$(date +%H%M%S)-$1.png"
  if [[ "$PLATFORM" == ios ]]; then xcrun simctl io "$DEVICE" screenshot "$f" >/dev/null 2>&1
  else adb -s "$DEVICE" exec-out screencap -p > "$f"; fi
  log "screenshot $f"
}

json_arg() { # <json> <key> : crude reader for flat numeric/string args
  echo "$1" | sed -nE "s/.*\"$2\" *: *\"?([^\",}]*)\"?.*/\1/p" | head -1
}

# Serves one request file; touches $OUT/.died when the action ends the app.
serve_one() {
  local req="$1" body seq action ok=true detail="" died=false
  body="$(read_shared "e2e_handshake/$req")"
  seq="$(json_arg "$body" seq)"
  action="$(json_arg "$body" action)"
  log "request #$seq $action $body"
  case "$action" in
    background)
      local secs; secs="$(json_arg "$body" seconds)"; secs="${secs:-3}"
      app_background; sleep "$secs"; app_foreground; sleep 0.5; detail="background ${secs}s" ;;
    foreground) app_foreground ;;
    grantMic)
      # iOS: `simctl privacy grant` terminates a running app, so run_file grants the microphone
      # before the phase starts and this request only confirms it.
      if [[ "$PLATFORM" == ios ]]; then detail="granted before launch"
      else grant_mic || { ok=false; detail="grant failed"; }; fi ;;
    grantNotifications)
      if [[ "$PLATFORM" == ios ]]; then detail="not needed on iOS"
      else grant_notifications || { ok=false; detail="grant failed"; }; fi ;;
    screenshot) screenshot "$(json_arg "$body" name)" ;;
    tapNotificationCancel)
      # The deterministic path sends the Cancel action's intent itself; the shade tap (uiautomator)
      # is the fallback when no job id is found or the intent is refused.
      if [[ "$PLATFORM" == android ]]; then
        if android_send_export_cancel; then detail="cancel intent sent"
        else
          adb -s "$DEVICE" shell cmd statusbar expand-notifications; sleep 1.5
          if android_tap_text "Cancel"; then detail="tapped Cancel in the shade"
          else ok=false; detail="no cancel intent accepted and no Cancel button in the shade"; fi
          adb -s "$DEVICE" shell cmd statusbar collapse
        fi
      else ok=false; detail="android only"; fi ;;
    kill) app_kill; died=true ;;
    swipeFromRecents)
      if [[ "$PLATFORM" != android ]]; then ok=false; detail="android only"
      elif android_swipe_from_recents; then died=true
      else ok=false; detail="the task is still in recents after 5 swipes"; fi ;;
    destroyActivity)
      if [[ "$PLATFORM" != android ]]; then ok=false; detail="android only"
      elif android_destroy_activity "$seq" "$action"; then died=true; detail="activity finished"
      else ok=false; detail="an ActivityRecord of $APP_ID is still listed"; fi ;;
    relaunch) app_foreground ;;
    *) ok=false; detail="unknown action $action" ;;
  esac
  # Actions that end the app are acked only once confirmed (for the record; the app may be gone);
  # a failed one is acked with ok=false, which E2eHandshake.requestAndDie turns into a failure.
  if [[ "$died" == false || "$action" == destroyActivity ]]; then
    write_shared "e2e_handshake/ack-$seq-$action.json" "{\"seq\":$seq,\"ok\":$ok,\"detail\":\"$detail\"}" || true
  fi
  # Requests are kept for the record but renamed so they are served once.
  if [[ "$PLATFORM" == ios ]]; then mv "$(ios_shared)/e2e_handshake/$req" "$(ios_shared)/e2e_handshake/done-$req"
  else adb -s "$DEVICE" shell "mv $ANDROID_SHARED/e2e_handshake/$req $ANDROID_SHARED/e2e_handshake/done-$req"; fi
  if [[ "$died" == true ]]; then touch "$OUT/.died"; fi
  return 0
}

# Serves requests while the flutter process <pid> runs. Exit 0 normally, 3 when an action ended the app.
serve() {
  local pid="$1" status=0 tick=0
  while kill -0 "$pid" 2>/dev/null; do
    # `flutter test` uninstalls the app when it ends (and the sandbox with it), so exported files
    # are copied out while the test still runs (every ~6 s), not only by `collect` at the end.
    tick=$((tick + 1)); if (( tick % 20 == 0 )); then collect_quietly; fi
    for req in $(list_requests); do
      rm -f "$OUT/.died"
      serve_one "$req" >> "$OUT/logs/host-actions.log" 2>&1 || log "action failed for $req"
      if [[ -f "$OUT/.died" ]]; then
        status=3
        # The test that asked is gone; give flutter a minute to notice, then stop it.
        for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill "$pid" 2>/dev/null || true
      fi
    done
    sleep 0.3
  done
  return $status
}

# ---- staging ------------------------------------------------------------------------------------

stage() {
  if [[ "$PLATFORM" == ios ]]; then
    log "iOS Simulator reads the fixtures in place: --dart-define=DV_E2E_FIXTURES=$FIXTURES"
  else
    adb -s "$DEVICE" shell mkdir -p "$ANDROID_SHARED/e2e_fixtures"
    for f in "$FIXTURES"/*; do
      [[ -f "$f" ]] && adb -s "$DEVICE" push "$f" "$ANDROID_SHARED/e2e_fixtures/" >/dev/null
    done
    log "pushed fixtures to $ANDROID_SHARED/e2e_fixtures"
  fi
}

stage_models() {
  local dir="${1:-$MODELS_DIR}"
  [[ -n "$dir" ]] || { echo "stage-models <dir with ${MODEL_FILES[*]}>"; exit 2; }
  for m in "${MODEL_FILES[@]}"; do [[ -f "$dir/$m" ]] || { echo "missing $dir/$m"; exit 1; }; done
  if [[ "$PLATFORM" == ios ]]; then
    log "iOS Simulator reads the models in place: --dart-define=DV_E2E_MODELS=$dir"
  else
    adb -s "$DEVICE" shell mkdir -p "$ANDROID_SHARED/e2e_models"
    for m in "${MODEL_FILES[@]}"; do adb -s "$DEVICE" push "$dir/$m" "$ANDROID_SHARED/e2e_models/" >/dev/null; done
    log "pushed models to $ANDROID_SHARED/e2e_models"
  fi
}

collect_quietly() {
  if [[ "$PLATFORM" == ios ]]; then
    local d; d="$(ios_shared)"; [[ -n "$d" && -d "$d/e2e_out" ]] && cp -R "$d/e2e_out/." "$OUT/files/" 2>/dev/null || true
  else
    adb -s "$DEVICE" pull "$ANDROID_SHARED/e2e_out/." "$OUT/files/" >/dev/null 2>&1 || true
  fi
}

collect() {
  if [[ "$PLATFORM" == ios ]]; then
    local d; d="$(ios_shared)"; [[ -n "$d" && -d "$d/e2e_out" ]] && cp -R "$d/e2e_out/." "$OUT/files/" || true
  else
    adb -s "$DEVICE" pull "$ANDROID_SHARED/e2e_out/." "$OUT/files/" >/dev/null 2>&1 || true
  fi
  log "collected exported files into $OUT/files"
}

# ---- running ------------------------------------------------------------------------------------

defines() {
  local d=(--dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true --dart-define=DV_E2E_HOST=true)
  if [[ "$PLATFORM" == ios ]]; then
    d+=(--dart-define=DV_E2E_FIXTURES="$FIXTURES")
    [[ -n "$MODELS_DIR" ]] && d+=(--dart-define=DV_E2E_MODELS="$MODELS_DIR")
  fi
  printf '%s\n' "${d[@]}" ${EXTRA_DEFINES[@]+"${EXTRA_DEFINES[@]}"}
}

# Runs <file> once with phase <phase>; <expect> is "pass" or "dies" (an action ends the app).
run_phase() {
  local file="$1" phase="$2" expect="$3" logf status
  logf="$OUT/logs/$(basename "$file" .dart)${phase:+-$phase}.log"
  log "flutter test $file phase='${phase}' (expect $expect)"
  local args=()
  while IFS= read -r line; do args+=("$line"); done < <(defines)
  (cd "$ROOT" && flutter test "$file" -d "$DEVICE" "${args[@]}" --dart-define=DV_E2E_PHASE="$phase") > "$logf" 2>&1 &
  local pid=$!
  # Watchdog: a phase that hangs (an engine call that never answers, a test stuck before its first
  # frame) is stopped after DV_E2E_PHASE_TIMEOUT seconds (default 900) and counts as failed.
  local limit="${DV_E2E_PHASE_TIMEOUT:-900}"
  ( for _ in $(seq 1 "$limit"); do kill -0 "$pid" 2>/dev/null || exit 0; sleep 1; done
    echo "[e2e_host] TIMEOUT after ${limit}s" >> "$logf"; pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null ) &
  local watchdog=$!
  set +e
  serve "$pid"; local served=$?
  wait "$pid"; status=$?
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  set -e
  if grep -q '^\[e2e_host\] TIMEOUT' "$logf" 2>/dev/null; then log "TIMEOUT $file ${phase} after ${limit}s (see $logf)"; status=124; fi
  if [[ "$expect" == dies ]]; then
    [[ $served -eq 3 ]] && { log "phase $phase ended the app as expected"; return 0; }
    log "phase $phase was expected to end the app (status $status)"; return 1
  fi
  if [[ $status -eq 0 ]]; then log "PASS $file ${phase}"; else log "FAIL $file ${phase} (see $logf)"; fi
  return $status
}

run_file() {
  local file="$1" name; name="$(basename "$file" .dart)"
  case "$name" in
    s13_voiceover_test)
      if [[ "$PLATFORM" == ios ]]; then grant_mic || log "microphone grant failed (is the app installed?)"; fi
      run_phase "$file" "" pass ;;
    s09_recovery_after_kill_test) run_phase "$file" edit dies && run_phase "$file" recover pass ;;
    x_android_export_background_test)
      [[ "$PLATFORM" == android ]] || { log "skip $name on $PLATFORM"; return 0; }
      run_phase "$file" fgs dies && run_phase "$file" fgs-check pass &&
        run_phase "$file" cancel pass &&
        run_phase "$file" swipe dies && run_phase "$file" swipe-check pass &&
        run_phase "$file" death dies && run_phase "$file" death-check pass ;;
    *) run_phase "$file" "" pass ;;
  esac
}

resolve() { # sNN | x_name | path | all
  case "$1" in
    all) ls "$ROOT/$SUITE"/s[0-9][0-9]_*_test.dart "$ROOT/$SUITE"/x_*_test.dart | sed "s|$ROOT/||" ;;
    s[0-9][0-9]) ls "$ROOT/$SUITE/$1"_*_test.dart | sed "s|$ROOT/||" ;;
    *.dart) echo "$1" ;;
    *) ls "$ROOT/$SUITE/$1"*_test.dart | sed "s|$ROOT/||" ;;
  esac
}

case "$CMD" in
  stage) stage ;;
  stage-models) stage_models "${1:-}" ;;
  collect) collect ;;
  run)
    [[ $# -ge 1 ]] || usage
    failed=0
    for f in $(resolve "$1"); do run_file "$f" || failed=$((failed + 1)); done
    collect
    log "done: $failed file(s) failed"
    [[ $failed -eq 0 ]] ;;
  serve) # serve requests until interrupted (when the test is started by another tool)
    sleep 2147483647 & serve $! ;;
  *) usage ;;
esac
