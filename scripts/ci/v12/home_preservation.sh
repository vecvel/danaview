#!/usr/bin/env bash
# OWNER: HOM-15
# home-preservation CI job, the merge gate of ARCH v1.2 V2-32 (BUILD_PLAN v1.2 HOM-15). Runs the
# player and library regression suite test/v12/preservation/suite_test.dart: the 1.1 Home, player,
# queue, library and incoming-media tests plus HOM-06…HOM-08, with DANAVIEW_FILES_HOME off and on.
# INT-101's `home-preservation` job calls it on every PR touching
# packages/danaview_features/lib/src/library/**, packages/danaview_platform/** or
# packages/danaview_library*/**.
#
# Usage:
#   bash scripts/ci/v12/home_preservation.sh               run the suite (exit 0 = green)
#   bash scripts/ci/v12/home_preservation.sh --self-check  prove the gate bites: copy the working
#       tree (tracked and untracked, non-ignored files) to a temp dir, plant a regression there
#       (the Continue watching header label changed), run the suite in the copy and require it to
#       fail. The real tree is never touched. Exit 0 = the planted regression was caught.
#
# Extra arguments after the mode are passed to `flutter test` (e.g. -j 1, --plain-name).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
in_ci="${GITHUB_ACTIONS:-false}"
suite="test/v12/preservation/suite_test.dart"

group() { if [ "$in_ci" = "true" ]; then echo "::group::$1"; else echo "== $1"; fi; }
endgroup() { if [ "$in_ci" = "true" ]; then echo "::endgroup::"; fi; }

run_suite() {
  local root="$1"
  shift
  (cd "$root" && flutter pub get >/dev/null && flutter test "$suite" "$@")
}

mode="run"
if [ "${1:-}" = "--self-check" ]; then
  mode="self-check"
  shift
fi

if [ ! -f "$repo/$suite" ]; then
  echo "home_preservation.sh: $suite is missing (owner: HOM-15)" >&2
  exit 1
fi

if [ "$mode" = "run" ]; then
  group "home preservation suite (DANAVIEW_FILES_HOME off and on)"
  run_suite "$repo" "$@"
  endgroup
  exit 0
fi

# --self-check: plant a regression in a scratch copy and require the suite to fail on it.
target="packages/danaview_features/lib/src/library/danaview_home_screen.dart"
label="'Continue watching',"
planted="'Continue Watching',"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/danaview_home_preservation.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

group "self-check: copy the working tree"
(cd "$repo" && git ls-files -co --exclude-standard -z \
  | while IFS= read -r -d '' f; do if [ -f "$f" ]; then printf '%s\0' "$f"; fi; done \
  | tar --null -T - -cf - | tar -xf - -C "$scratch")
endgroup

if ! grep -qF "$label" "$scratch/$target"; then
  echo "home_preservation.sh --self-check: the Continue watching label is not in $target any more;" >&2
  echo "update the planted regression in this script." >&2
  exit 1
fi

group "self-check: plant a changed Continue watching label"
# Replace only the first occurrence (the 1.1 hub header), portable across BSD and GNU sed.
awk -v from="$label" -v to="$planted" '!done && index($0, from) { sub(from, to); done = 1 } { print }' \
  "$scratch/$target" > "$scratch/$target.planted"
mv "$scratch/$target.planted" "$scratch/$target"
grep -qF "$planted" "$scratch/$target"
endgroup

group "self-check: the suite must fail on the planted regression"
if run_suite "$scratch" "$@"; then
  echo "home_preservation.sh --self-check: FAILED, the suite passed with a changed Continue watching label" >&2
  exit 1
fi
endgroup
echo "home_preservation.sh --self-check: OK, the planted regression fails the suite"
