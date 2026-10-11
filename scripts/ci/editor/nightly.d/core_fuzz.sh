#!/usr/bin/env bash
# OWNER: CORE-34
#
# Nightly model fuzzer (BUILD_PLAN CORE-34, ARCH §21.1): random projects × random command
# sequences from every command group, run through EditSession with every check after every step
# (validator, undo^n/redo^n identity, stamps, JSON round trip, plan diff/patch identity, dry run
# versus apply, no escaping exceptions). The CI job dart-core runs the 200-seed fuzz-lite subset
# inside `dart test`; this script runs 10,000 seeds.
#
# The seed range moves every day, so each night explores new seeds; the log and report name it.
# Failing seeds are minimized and written as regression fixtures to $CORE_FUZZ_OUT/fixtures/
# (copy them into packages/vwish_editor_core/test/fuzz/regressions/). The report with the command
# coverage table is $CORE_FUZZ_OUT/report.json.
#
# Environment:
#   CORE_FUZZ_SEEDS   number of seeds (default 10000)
#   CORE_FUZZ_FIRST   first seed (default: moves with the UTC date)
#   CORE_FUZZ_STEPS   steps per seed (default 500)
#   CORE_FUZZ_JOBS    worker isolates (default: the processor count)
#   CORE_FUZZ_OUT     report directory (default packages/vwish_editor_core/build/core_fuzz)
#   CORE_FUZZ_STRICT  1 to fail on the open known defects too (default 0)
#
# Exit status: 0 when every seed passed and every EditCommand subtype was exercised.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PKG="$ROOT/packages/vwish_editor_core"

SEEDS="${CORE_FUZZ_SEEDS:-10000}"
STEPS="${CORE_FUZZ_STEPS:-500}"
if [ -n "${CORE_FUZZ_FIRST:-}" ]; then
  FIRST="$CORE_FUZZ_FIRST"
else
  # Day number since the epoch picks one of 1000 seed blocks above the fuzz-lite seeds.
  FIRST=$(( 1000000 + ( $(date -u +%s) / 86400 % 1000 ) * SEEDS ))
fi
if [ -n "${CORE_FUZZ_JOBS:-}" ]; then
  JOBS="$CORE_FUZZ_JOBS"
else
  JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
fi
OUT="${CORE_FUZZ_OUT:-$PKG/build/core_fuzz}"
STRICT=()
if [ "${CORE_FUZZ_STRICT:-0}" = 1 ]; then STRICT=(--strict); fi

cd "$PKG"
dart pub get >/dev/null
echo "core_fuzz: seeds $FIRST..$((FIRST + SEEDS - 1)), $STEPS steps, $JOBS jobs, report $OUT/report.json"
status=0
dart run test/fuzz/fuzz_main.dart --first "$FIRST" --seeds "$SEEDS" --steps "$STEPS" --jobs "$JOBS" \
  --out "$OUT" --require-coverage "${STRICT[@]+"${STRICT[@]}"}" || status=$?
if [ "$status" -ne 0 ] && [ -d "$OUT/fixtures" ]; then
  echo "core_fuzz: minimized regression fixtures:"
  find "$OUT/fixtures" -name '*.json' -print | sed 's/^/  /'
fi
exit "$status"
