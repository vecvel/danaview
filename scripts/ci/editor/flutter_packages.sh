#!/usr/bin/env bash
# OWNER: INT-01
#
# flutter-packages CI job (ARCH §22): `flutter analyze` + `flutter test` for every editor Flutter
# package that exists, then the root architecture tests (test/architecture/).
#
# Usage:
#   scripts/ci/editor/flutter_packages.sh                 # every package + architecture tests
#   scripts/ci/editor/flutter_packages.sh danaview_editor    # only the named package(s)
#   scripts/ci/editor/flutter_packages.sh architecture    # only the root architecture tests
#
# Environment:
#   DANAVIEW_CI_EXCLUDE_TAGS  test tags left out of PR runs (default: nightly; nightly.d/ scripts
#                          run them). Set to an empty string to run everything.
#
# Packages that don't exist yet are skipped with a notice. Every package runs even when an
# earlier one fails; the script exits 1 if any step failed and prints a summary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

# Every editor Flutter package of this release (ARCH §4.1). danaview_editor_core is pure Dart and
# runs in the dart-core job (core.sh).
PACKAGES=(
  danaview_editor_engine_api
  danaview_editor_engine
  danaview_transcription
  danaview_whisper
  danaview_editor_fonts
  danaview_editor
)
EXCLUDE_TAGS="${DANAVIEW_CI_EXCLUDE_TAGS-nightly}"

declare -a SELECTED=()
RUN_ARCHITECTURE=true
if [ "$#" -gt 0 ]; then
  RUN_ARCHITECTURE=false
  for arg in "$@"; do
    case "$arg" in
      architecture) RUN_ARCHITECTURE=true ;;
      -h | --help)
        sed -n '2,17p' "$0"
        exit 0
        ;;
      *)
        known=false
        for pkg in "${PACKAGES[@]}"; do
          if [ "$pkg" = "$arg" ]; then known=true; fi
        done
        if [ "$known" != true ]; then
          echo "unknown package '$arg' (known: ${PACKAGES[*]} architecture)" >&2
          exit 2
        fi
        SELECTED+=("$arg")
        ;;
    esac
  done
else
  SELECTED=("${PACKAGES[@]}")
fi

declare -a PASSED=()
declare -a FAILED=()
declare -a SKIPPED=()

group() { if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::group::$1"; else echo "==> $1"; fi; }
endgroup() { if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::endgroup::"; fi; }
notice() { if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::notice title=flutter-packages::$1"; else echo "note: $1"; fi; }
failure() { if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error title=flutter-packages::$1"; else echo "FAILED: $1" >&2; fi; }

# step <label> <dir> <command...>: runs the command in <dir>, records a failure, returns its status.
step() {
  local label="$1" dir="$2"
  shift 2
  group "$label"
  local status=0
  (cd "$dir" && "$@") || status=$?
  endgroup
  if [ "$status" -ne 0 ]; then
    failure "$label (exit $status)"
    FAILED+=("$label")
  fi
  return "$status"
}

has_tests() { [ -d "$1/test" ] && [ -n "$(find "$1/test" -name '*_test.dart' -print -quit)" ]; }

test_args() {
  if [ -n "$EXCLUDE_TAGS" ]; then printf '%s\n' "--exclude-tags" "$EXCLUDE_TAGS"; fi
}

run_package() {
  local pkg="$1" dir="packages/$1"
  if [ ! -f "$dir/pubspec.yaml" ]; then
    notice "packages/$pkg does not exist yet; skipped"
    SKIPPED+=("$pkg")
    return 0
  fi
  step "$pkg: flutter pub get" "$dir" flutter pub get || return 0
  # A plugin's example host is a nested package that the analyzer covers too.
  if [ -f "$dir/example/pubspec.yaml" ]; then
    step "$pkg/example: flutter pub get" "$dir/example" flutter pub get || return 0
  fi
  step "$pkg: flutter analyze" "$dir" flutter analyze --fatal-infos --fatal-warnings || return 0
  if has_tests "$dir"; then
    local args=()
    while IFS= read -r a; do args+=("$a"); done < <(test_args)
    step "$pkg: flutter test" "$dir" flutter test "${args[@]+"${args[@]}"}" || return 0
  else
    notice "$pkg has no tests yet; analyze only"
  fi
  PASSED+=("$pkg")
}

run_architecture() {
  step "root: flutter pub get" "$ROOT" flutter pub get || return 0
  step "architecture: flutter analyze" "$ROOT" flutter analyze --fatal-infos --fatal-warnings test/architecture || return 0
  step "architecture: flutter test" "$ROOT" flutter test test/architecture || return 0
  PASSED+=("architecture")
}

for pkg in "${SELECTED[@]+"${SELECTED[@]}"}"; do
  run_package "$pkg"
done
if [ "$RUN_ARCHITECTURE" = true ]; then
  run_architecture
fi

echo
echo "flutter-packages summary"
echo "  passed:  ${PASSED[*]:-none}"
echo "  skipped: ${SKIPPED[*]:-none}"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "  failed:"
  for f in "${FAILED[@]}"; do echo "    - $f"; done
  exit 1
fi
echo "  failed:  none"
