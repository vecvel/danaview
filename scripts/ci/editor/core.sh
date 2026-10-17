#!/usr/bin/env bash
# OWNER: CORE-01
# dart-core CI job (ARCH §22): analyze + test danaview_editor_core with plain Dart (no Flutter needed),
# check the shared frame-grid vectors, and run the benchmarks gate once CORE-35 adds benchmark/.
set -euo pipefail
cd "$(dirname "$0")/../../../packages/danaview_editor_core"
dart pub get
dart analyze --fatal-infos
dart run tool/gen_frame_vectors.dart --check
dart test
if [ -d benchmark ] && [ -f benchmark/run.dart ]; then
  dart run benchmark/run.dart --check
fi
