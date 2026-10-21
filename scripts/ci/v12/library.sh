#!/usr/bin/env bash
# OWNER: INT-101
# v12-dart CI job (BUILD_PLAN v1.2 INT-101; ARCH v1.2 §12): analyze (--fatal-infos) and test the pure
# Dart 1.2.0 packages danaview_library and danaview_search, then the core photo, colour and beauty
# tests of danaview_editor_core (VED tickets) with the core's purity and barrel contract. Nothing is
# downloaded beyond pub dependency resolution; no test reaches the network.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
in_ci="${GITHUB_ACTIONS:-false}"

group() { if [ "$in_ci" = "true" ]; then echo "::group::$1"; else echo "== $1"; fi; }
endgroup() { if [ "$in_ci" = "true" ]; then echo "::endgroup::"; fi; }

for pkg in danaview_library danaview_search; do
  dir="$repo/packages/$pkg"
  if [ ! -f "$dir/pubspec.yaml" ]; then
    echo "library.sh: packages/$pkg is missing (INT-101 creates it)" >&2
    exit 1
  fi
  group "$pkg (dart)"
  (cd "$dir" && dart pub get && dart analyze --fatal-infos && dart test)
  endgroup
done

core="$repo/packages/danaview_editor_core"
group "danaview_editor_core photo, colour and beauty tests"
targets=(test/purity_test.dart)
for t in test/photo test/color test/beauty test/ops/photo_bridge test/ops/beauty test/eval/easing test/model/beauty test/plan/beauty test/store/photo_store_test.dart; do
  [ -e "$core/$t" ] && targets+=("$t")
done
(cd "$core" && dart pub get && dart analyze --fatal-infos && dart test "${targets[@]}")
endgroup
