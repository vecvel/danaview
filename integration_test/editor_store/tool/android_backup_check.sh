#!/usr/bin/env bash
# OWNER: QA-10
#
# V-A7 (ARCH §8.1, CORE-28): Android Auto Backup and device transfer exclude the editor and speech
# trees (`files/danaview/editor/` and `files/danaview/speech/`), while the rest of the app's data
# (player library, profile, shared preferences) is still backed up. Windows lane (QA-02 / AND-xx):
# run it on the API 35 x86_64 emulator (google_apis image, `adb root` available) after QA-10's
# `qa10_host.py -p android ... run seed edit` left editor data behind, and on one physical device
# for the bmgr part (the archive listing needs root, so on a device only the transport log is read).
#
#   integration_test/editor_store/tool/android_backup_check.sh -d emulator-5554
#
# Steps (the `bmgr` procedure of the Android "Test backup" guide):
#   1. make sure editor data exists: files/danaview/editor/{projects,media} and files/danaview/speech
#      (written by the QA-10 edit phase; the script plants two marker files as well);
#   2. select the local transport, enable backup, run `bmgr backupnow <pkg>` (full-data backup);
#   3. list the produced archive (`/data/data/com.android.localtransport/files/` on API 28+) and fail
#      when any entry lies under danaview/editor or danaview/speech, and when no other app file is
#      in it (the rules must exclude only those trees);
#   4. the device-transfer rules (API 31+, <device-transfer> in danaview_data_extraction_rules.xml) are
#      checked statically: both trees are excluded there too.
#   5. optional V-D1 evidence on a userdebug/emulator image: strace the app during an autosave
#      (`-s` flag) and look for fsync on project.dnproj.tmp-*.
#
# Evidence lands in build/qa10/android/<device>/backup/.

set -euo pipefail

APP_ID="com.vecvel.danaview"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEVICE=""
STRACE=false
while getopts "d:s" opt; do
  case "$opt" in
    d) DEVICE="$OPTARG" ;;
    s) STRACE=true ;;
    *) sed -n '2,30p' "$0"; exit 2 ;;
  esac
done
[[ -n "$DEVICE" ]] || { sed -n '2,30p' "$0"; exit 2; }
OUT="$ROOT/build/qa10/android/$DEVICE/backup"
mkdir -p "$OUT"
A=(adb -s "$DEVICE")
log() { echo "[android_backup_check] $*" | tee -a "$OUT/log.txt" >&2; }
fail=0

# 4. Static rules (no device needed).
RULES31="$ROOT/android/app/src/main/res/xml/danaview_data_extraction_rules.xml"
RULES30="$ROOT/android/app/src/main/res/xml/danaview_backup_rules.xml"
for f in "$RULES31" "$RULES30"; do
  if [[ ! -f "$f" ]]; then log "FAIL missing $f"; fail=1; continue; fi
  for tree in danaview/editor danaview/speech; do
    n="$(grep -c "exclude[^>]*path=\"$tree" "$f" || true)"
    want=1; [[ "$f" == "$RULES31" ]] && want=2 # cloud-backup and device-transfer
    if (( n < want )); then log "FAIL $f excludes $tree $n time(s), expected $want"; fail=1; else log "ok $f excludes $tree ($n)"; fi
  done
done
grep -q 'android:dataExtractionRules="@xml/danaview_data_extraction_rules"' "$ROOT/android/app/src/main/AndroidManifest.xml" \
  && log "ok manifest dataExtractionRules" || { log "FAIL manifest lacks dataExtractionRules"; fail=1; }
grep -q 'android:fullBackupContent="@xml/danaview_backup_rules"' "$ROOT/android/app/src/main/AndroidManifest.xml" \
  && log "ok manifest fullBackupContent" || { log "FAIL manifest lacks fullBackupContent"; fail=1; }

# 1. Plant markers inside and outside the excluded trees (run-as works on debug builds).
"${A[@]}" shell run-as "$APP_ID" sh -c 'mkdir -p files/danaview/editor/projects files/danaview/speech files/qa10_control &&
  echo qa10 > files/danaview/editor/projects/qa10_marker.txt && echo qa10 > files/danaview/speech/qa10_marker.txt &&
  echo qa10 > files/qa10_control/kept.txt'
log "planted markers"

# 2. Local transport + full backup.
"${A[@]}" shell bmgr enable true
"${A[@]}" shell bmgr list transports | tee "$OUT/transports.txt"
"${A[@]}" shell bmgr transport com.android.localtransport/.LocalTransport | tee -a "$OUT/log.txt"
"${A[@]}" shell bmgr backupnow "$APP_ID" | tee "$OUT/backupnow.txt"
grep -q "Success" "$OUT/backupnow.txt" || { log "FAIL bmgr backupnow did not report Success"; fail=1; }

# 3. Archive listing (root: emulator google_apis images).
if "${A[@]}" root >/dev/null 2>&1; then
  sleep 2
  "${A[@]}" wait-for-device
  ARCH="$("${A[@]}" shell "find /data/data/com.android.localtransport/files -path '*$APP_ID*' -type f 2>/dev/null" | tr -d '\r' | head -1)"
  if [[ -z "$ARCH" ]]; then
    log "FAIL no local-transport archive for $APP_ID"; fail=1
  else
    "${A[@]}" pull "$ARCH" "$OUT/backup.tar" >/dev/null
    # Full-data backups are a tar stream ('apps/<pkg>/f/...' entries); strip a possible ab header.
    tar -tf "$OUT/backup.tar" > "$OUT/listing.txt" 2>/dev/null || (tail -c +25 "$OUT/backup.tar" | zlib-flate -uncompress 2>/dev/null | tar -t > "$OUT/listing.txt")
    if grep -E 'danaview/(editor|speech)/' "$OUT/listing.txt"; then log "FAIL excluded trees present in the backup"; fail=1; else log "ok no editor/speech entries"; fi
    if grep -q 'qa10_control/kept.txt' "$OUT/listing.txt"; then log "ok control file backed up"; else log "FAIL the control file is missing (rules exclude too much?)"; fail=1; fi
  fi
else
  log "no root on this device: archive listing skipped (record the backupnow result only; physical-device check)"
fi

# 5. Optional fsync trace (V-D1 on Android).
if $STRACE; then
  PID="$("${A[@]}" shell pidof "$APP_ID" | tr -d '\r')"
  if [[ -n "$PID" ]]; then
    log "strace on pid $PID for 30 s: make an edit in the editor now (autosave)"
    "${A[@]}" shell "timeout 30 strace -f -e trace=fsync,fdatasync,renameat -p $PID" > "$OUT/strace.txt" 2>&1 || true
    grep -E 'fsync|fdatasync' "$OUT/strace.txt" | head -20 | tee -a "$OUT/log.txt" || log "no fsync seen"
  else
    log "app not running: strace skipped"
  fi
fi

"${A[@]}" shell run-as "$APP_ID" sh -c 'rm -f files/danaview/editor/projects/qa10_marker.txt files/danaview/speech/qa10_marker.txt; rm -rf files/qa10_control'
[[ $fail -eq 0 ]] && log "V-A7 PASS" || log "V-A7 FAIL"
exit $fail
