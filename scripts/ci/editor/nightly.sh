#!/usr/bin/env bash
# OWNER: INT-01
#
# nightly CI job (ARCH §22): runs every scripts/ci/editor/nightly.d/*.sh in name order from the
# repository root. Each nightly.d script is owned by the ticket that adds it (core_fuzz.sh CORE-34,
# ai_eval.sh QA-06, overflow_full.sh QA-09; see README.md).
#
# Usage:
#   scripts/ci/editor/nightly.sh                    # every nightly.d/*.sh
#   scripts/ci/editor/nightly.sh core_fuzz          # only the named script(s), with or without .sh
#   scripts/ci/editor/nightly.sh --list             # list the scripts and exit
#
# Every script runs even when an earlier one fails; the job exits 1 if any failed and prints a
# summary with the single command that reproduces each failure.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
NIGHTLY_DIR="$HERE/nightly.d"

group() { if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::group::$1"; else echo "==> $1"; fi; }
endgroup() { if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::endgroup::"; fi; }
notice() { if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::notice title=nightly::$1"; else echo "note: $1"; fi; }
failure() { if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error title=nightly::$1"; else echo "FAILED: $1" >&2; fi; }

declare -a ALL=()
if [ -d "$NIGHTLY_DIR" ]; then
  while IFS= read -r f; do ALL+=("$f"); done < <(find "$NIGHTLY_DIR" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort)
fi

if [ "${1:-}" = "--list" ]; then
  for f in "${ALL[@]+"${ALL[@]}"}"; do basename "$f"; done
  exit 0
fi
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,14p' "$0"
  exit 0
fi

declare -a SELECTED=()
if [ "$#" -gt 0 ]; then
  for arg in "$@"; do
    name="${arg%.sh}.sh"
    if [ ! -f "$NIGHTLY_DIR/$name" ]; then
      echo "no nightly script scripts/ci/editor/nightly.d/$name" >&2
      exit 2
    fi
    SELECTED+=("$NIGHTLY_DIR/$name")
  done
else
  SELECTED=("${ALL[@]+"${ALL[@]}"}")
fi

if [ "${#SELECTED[@]}" -eq 0 ]; then
  notice "no scripts in scripts/ci/editor/nightly.d/ yet; nothing to run"
  exit 0
fi

declare -a PASSED=()
declare -a FAILED=()
for script in "${SELECTED[@]}"; do
  name="$(basename "$script")"
  group "nightly.d/$name"
  start=$(date +%s)
  status=0
  (cd "$ROOT" && bash "$script") || status=$?
  elapsed=$(($(date +%s) - start))
  endgroup
  if [ "$status" -eq 0 ]; then
    PASSED+=("$name (${elapsed}s)")
  else
    failure "nightly.d/$name exited $status after ${elapsed}s"
    FAILED+=("$name")
  fi
done

echo
echo "nightly summary"
echo "  passed: ${PASSED[*]:-none}"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "  failed (reproduce with the command shown):"
  for name in "${FAILED[@]}"; do echo "    - scripts/ci/editor/nightly.sh ${name%.sh}"; done
  exit 1
fi
echo "  failed: none"
