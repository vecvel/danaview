#!/usr/bin/env bash
# IOS-01 spike: build and run the hosted spike tests on one destination and collect the
# `DVSPIKE-METRIC {json}` lines into results/<label>.metrics.jsonl (+ the full log).
#
# Usage: tools/run_spike_tests.sh <simulator-udid|device-udid> <label> [-only-testing:DVSpikeTests/X ...]
# Example: tools/run_spike_tests.sh 1E6364B5-604C-4CB1-BFFC-B699C3B24EF2 ios26-sim
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$1"; LABEL="$2"; shift 2
cd "$HERE"
mkdir -p results
LOG="results/$LABEL.log"
xcodebuild -workspace DVSpikeHost.xcworkspace -scheme DVSpikeHost -destination "id=$DEST" \
  -derivedDataPath build/DerivedData build-for-testing > "results/$LABEL.build.log" 2>&1 \
  || { grep -E ": error:" "results/$LABEL.build.log" | sort -u; exit 1; }
rm -rf "results/$LABEL.xcresult"  # left behind by an interrupted run
set +e
xcodebuild -workspace DVSpikeHost.xcworkspace -scheme DVSpikeHost -destination "id=$DEST" \
  -derivedDataPath build/DerivedData -resultBundlePath "results/$LABEL.xcresult" \
  test-without-building "$@" > "$LOG" 2>&1
STATUS=$?
set -e
rm -rf "results/$LABEL.xcresult"
grep -o 'DVSPIKE-METRIC {.*}' "$LOG" | sed 's/^DVSPIKE-METRIC //' > "results/$LABEL.metrics.jsonl" || true
grep -E "Test Case .*(passed|failed)|error: -\[|\*\* TEST" "$LOG" | sed 's/^.*Test Case //'
echo "metrics: results/$LABEL.metrics.jsonl ($(wc -l < "results/$LABEL.metrics.jsonl") lines)"
exit $STATUS
