#!/usr/bin/env bash
# OWNER: INT-101
# v12-flutter CI job, face tracking leg (BUILD_PLAN v1.2 INT-101; ARCH v1.2 §12): analyze
# (--fatal-infos) and test the Dart side of danaview_face_tracking. Its native tracker tests run in the
# ios job (VED-16) and on the Android lane (VED-16A). No model is downloaded: tests use fakes and the
# synthetic fixtures of ARCH v1.2 V2-31.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
in_ci="${GITHUB_ACTIONS:-false}"

group() { if [ "$in_ci" = "true" ]; then echo "::group::$1"; else echo "== $1"; fi; }
endgroup() { if [ "$in_ci" = "true" ]; then echo "::endgroup::"; fi; }

dir="$repo/packages/danaview_face_tracking"
if [ ! -f "$dir/pubspec.yaml" ]; then
  echo "face.sh: packages/danaview_face_tracking is missing (INT-101 creates it)" >&2
  exit 1
fi
group "danaview_face_tracking (flutter)"
(cd "$dir" && flutter pub get && flutter analyze --fatal-infos && flutter test)
endgroup
