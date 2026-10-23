#!/usr/bin/env bash
# OWNER: INT-101
# v12-flutter CI job, documents leg (BUILD_PLAN v1.2 INT-101; ARCH v1.2 §12): analyze (--fatal-infos)
# and test danaview_documents, danaview_pdf and danaview_library_native (Dart side; native tests run
# in the ios job and on the Android lane), analyze danaview_features (it gains the library, native,
# documents and search dependencies), then run the root architecture test and the 1.2.0 root tests
# under test/v12/.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
in_ci="${GITHUB_ACTIONS:-false}"

group() { if [ "$in_ci" = "true" ]; then echo "::group::$1"; else echo "== $1"; fi; }
endgroup() { if [ "$in_ci" = "true" ]; then echo "::endgroup::"; fi; }

for pkg in danaview_library_native danaview_pdf danaview_documents; do
  dir="$repo/packages/$pkg"
  if [ ! -f "$dir/pubspec.yaml" ]; then
    echo "documents.sh: packages/$pkg is missing (INT-101 creates it)" >&2
    exit 1
  fi
  group "$pkg (flutter)"
  (cd "$dir" && flutter pub get && flutter analyze --fatal-infos && flutter test)
  endgroup
done

group "danaview_features (analyze)"
(cd "$repo/packages/danaview_features" && flutter pub get && flutter analyze --fatal-infos)
endgroup

group "root: architecture rules and test/v12"
(cd "$repo" && flutter pub get && flutter test test/architecture test/v12)
endgroup
