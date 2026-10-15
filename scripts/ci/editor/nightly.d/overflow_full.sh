#!/usr/bin/env bash
# OWNER: QA-09
#
# Nightly no-overflow matrix (BUILD_PLAN QA-09, ARCH §1.3 rule 5, §17.9). Runs, over the FULL
# matrix (14 sizes x text scale 0.85/1.0/1.35 x keyboard none/40% = 84 surfaces,
# `--dart-define=DANAVIEW_SURFACE_MATRIX=full`):
#   1. packages/danaview_editor/test/overflow/ (QA-09's long-content suite with real fonts), and
#   2. every other danaview_editor test file with per-ticket matrix tests (files outside test/support/ calling
#      `testSurfaces(`, discovered at run time, so new matrix tests join automatically);
#   3. at the repository root, the Home header and player matrix tests (danaview_features surfaces):
#      test/editor_entry/home_edit_button_test.dart and test/editor_entry/player_edit_action_test.dart.
# flutter-packages CI runs the same danaview_editor tests over the 6-surface PR subset.
#
# Usage:
#   scripts/ci/editor/nightly.d/overflow_full.sh                       # everything above
#   scripts/ci/editor/nightly.d/overflow_full.sh --suite               # only test/overflow/
#   scripts/ci/editor/nightly.d/overflow_full.sh --root                # only the root entry tests
#   scripts/ci/editor/nightly.d/overflow_full.sh [--name '<test name>'] [--surface '<surface>'] <file>...
#                                                                      # chosen danaview_editor files
# A failure prints, for each failing test, the single command that reproduces it, e.g.
#   scripts/ci/editor/nightly.d/overflow_full.sh --name 'editor with every inspector panel [280x500 @1.35 kb40% android]' test/overflow/editor_inspector_overflow_test.dart
#
# Options and environment:
#   --name <plain name>   only tests whose name contains it (flutter test --plain-name)
#   --surface <name>      test/overflow tests run on that one surface only, e.g. '568x320 @1.35 android'
#                         (DANAVIEW_OVERFLOW_SURFACE)
#   --strict              also fail on the open known defects of test/overflow/overflow_rig.dart
#   OVERFLOW_STRICT=1     same as --strict (default 0: known defects print as KNOWN DEFECT)
#   OVERFLOW_JOBS         test files run in parallel (default 2; the matrix is memory-heavy)
#   OVERFLOW_OUT          log directory (default packages/danaview_editor/build/overflow_full)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PKG="$ROOT/packages/danaview_editor"
SELF="scripts/ci/editor/nightly.d/overflow_full.sh"
ROOT_TESTS=(test/editor_entry/home_edit_button_test.dart test/editor_entry/player_edit_action_test.dart)

JOBS="${OVERFLOW_JOBS:-2}"
OUT="${OVERFLOW_OUT:-$PKG/build/overflow_full}"
STRICT="${OVERFLOW_STRICT:-0}"
NAME=""
SURFACE=""
MODE="all"
declare -a FILES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --suite) MODE="suite" ;;
    --root) MODE="root" ;;
    --strict) STRICT=1 ;;
    --name)
      NAME="${2:?--name needs a value}"
      shift
      ;;
    --surface)
      SURFACE="${2:?--surface needs a value}"
      shift
      ;;
    -h | --help)
      sed -n '2,34p' "$0"
      exit 0
      ;;
    -*)
      echo "unknown option $1 (see --help)" >&2
      exit 2
      ;;
    *) FILES+=("${1#packages/danaview_editor/}") ;;
  esac
  shift
done
if [ "${#FILES[@]}" -gt 0 ]; then MODE="files"; fi
REPRO_FLAGS=""
if [ "$STRICT" = 1 ]; then REPRO_FLAGS=" --strict"; fi

group() { if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::group::$1"; else echo "==> $1"; fi; }
endgroup() { if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::endgroup::"; fi; }
failure() { if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error title=overflow_full::$1"; else echo "FAILED: $1" >&2; fi; }

mkdir -p "$OUT"
declare -a FAILED_CMDS=()
status=0

# Prints the reproduce command of every failing test in the expanded-reporter log $1. $2 is the
# file list of the run (used when the reporter omits the file because only one file ran).
reproduce_from_log() {
  local log="$1" only_file="$2"
  # Lines look like "01:23 +12 -1: test/overflow/x_test.dart: name [surface] [E]" (several files)
  # or "01:23 +12 -1: name [surface] [E]" (one file).
  grep -E ' \[E\]$' "$log" | sed -E 's/^[0-9:]+ [^:]*: //; s/ \[E\]$//' | sort -u | while IFS= read -r line; do
    local file="$only_file" name="$line"
    case "$line" in
      loading\ *)
        echo "$SELF$REPRO_FLAGS ${line#loading }"
        continue
        ;;
      test/*.dart:\ * | /*.dart:\ *)
        file="${line%%.dart: *}.dart"
        name="${line#*.dart: }"
        ;;
    esac
    file="${file#"$PKG"/}"
    printf "%s%s --name '%s' %s\n" "$SELF" "$REPRO_FLAGS" "${name//\'/\'\\\'\'}" "$file"
  done
}

run_package() {
  local label="$1"
  shift
  local log="$OUT/$label.log"
  local -a args=(--dart-define=DANAVIEW_SURFACE_MATRIX=full --concurrency "$JOBS" -r expanded)
  if [ "$STRICT" = 1 ]; then args+=(--dart-define=DANAVIEW_OVERFLOW_STRICT=true); fi
  if [ -n "$SURFACE" ]; then args+=("--dart-define=DANAVIEW_OVERFLOW_SURFACE=$SURFACE"); fi
  if [ -n "$NAME" ]; then args+=(--plain-name "$NAME"); fi
  group "danaview_editor: $label ($# file(s), full matrix)"
  local rc=0
  (cd "$PKG" && flutter test "${args[@]}" "$@") 2>&1 | tee "$log" || rc=$?
  if [ "$rc" -eq 0 ] && grep -q 'Some tests failed' "$log"; then rc=1; fi
  endgroup
  if [ "$rc" -ne 0 ]; then
    status=1
    failure "danaview_editor $label: failing tests (log $log)"
    local single=""
    if [ "$#" -eq 1 ]; then single="$1"; fi
    while IFS= read -r cmd; do FAILED_CMDS+=("$cmd"); done < <(reproduce_from_log "$log" "$single")
    if [ "${#FAILED_CMDS[@]}" -eq 0 ]; then FAILED_CMDS+=("$SELF $*"); fi
  fi
  local known
  known="$(grep -c '^KNOWN DEFECT' "$log" || true)"
  if [ "${known:-0}" -gt 0 ]; then
    echo "note: $known KNOWN DEFECT line(s) in $label (see $log; fail on them with --strict)"
    grep '^KNOWN DEFECT' "$log" | sed -E 's/: \[.*//' | sort | uniq -c | sed 's/^/  /'
  fi
}

run_root() {
  local log="$OUT/root_entry.log"
  group "root: Home header and player matrix tests"
  local rc=0
  (cd "$ROOT" && flutter pub get >/dev/null && flutter test -r expanded "${ROOT_TESTS[@]}") 2>&1 | tee "$log" || rc=$?
  endgroup
  if [ "$rc" -ne 0 ]; then
    status=1
    failure "root entry-point overflow tests (log $log)"
    for t in "${ROOT_TESTS[@]}"; do FAILED_CMDS+=("(cd $ROOT && flutter test $t)"); done
  fi
}

discover_matrix_files() {
  (cd "$PKG" && grep -rl --include='*_test.dart' 'testSurfaces(' test | grep -v -e '^test/overflow/' -e '^test/support/' | LC_ALL=C sort)
}

(cd "$PKG" && flutter pub get >/dev/null)
case "$MODE" in
  files) run_package selected "${FILES[@]}" ;;
  suite) run_package suite test/overflow ;;
  root) run_root ;;
  all)
    run_package suite test/overflow
    declare -a MATRIX=()
    while IFS= read -r f; do MATRIX+=("$f"); done < <(discover_matrix_files)
    if [ "${#MATRIX[@]}" -gt 0 ]; then run_package per_ticket "${MATRIX[@]}"; fi
    run_root
    ;;
esac

echo
echo "overflow_full summary (logs in $OUT)"
if [ "$status" -ne 0 ]; then
  echo "  failed; reproduce each failure with:"
  for c in "${FAILED_CMDS[@]}"; do echo "    $c"; done
  exit 1
fi
echo "  failed: none"
