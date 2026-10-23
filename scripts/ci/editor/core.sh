#!/usr/bin/env bash
# OWNER: CORE-01
# dart-core CI jobs (ARCH §22): analyze + test danaview_editor_core with plain Dart (no Flutter needed),
# check the shared frame-grid vectors, and run the benchmark gate (CORE-35).
#
# Usage: scripts/ci/editor/core.sh [all|test|benchmark]   (default: all)
#   test       analyze, frame vectors, dart test            (CI job dart-core, macos-26: JSON goldens)
#   benchmark  dart run benchmark/run.dart --check          (CI job dart-core-benchmark, ubuntu-latest:
#              the host benchmark/baseline.json is recorded on; see the package README)
set -euo pipefail
MODE="${1:-all}"
case "$MODE" in all|test|benchmark) ;; *) echo "usage: $0 [all|test|benchmark]" >&2; exit 2 ;; esac
cd "$(dirname "$0")/../../../packages/danaview_editor_core"
dart pub get
if [ "$MODE" != benchmark ]; then
  dart analyze --fatal-infos
  dart run tool/gen_frame_vectors.dart --check
  dart test
fi
if [ "$MODE" != test ] && [ -d benchmark ] && [ -f benchmark/run.dart ]; then
  # The JSON report is printed so a baseline refresh can be taken from the CI log of the gate host.
  report="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/danaview_core_benchmark.json"
  status=0
  dart run benchmark/run.dart --check --json "$report" || status=$?
  if [ -n "${GITHUB_ACTIONS:-}" ] && [ -f "$report" ]; then
    echo "::group::benchmark report (benchmark/baseline.json format)"
    cat "$report"
    echo "::endgroup::"
  fi
  exit "$status"
fi
