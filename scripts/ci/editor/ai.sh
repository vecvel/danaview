#!/usr/bin/env bash
# OWNER: AIS-01
# ai-dart CI job (AI_STUDIO_PLAN §5.5 AIS-01; ARCH v1.2 §12): analyze (--fatal-infos) and test the
# AI packages. danaview_ai_providers is pure Dart (dart pub/analyze/test); danaview_ai_studio needs
# Flutter only because danaview_transcription does (flutter pub/analyze/test). danaview_ai and
# danaview_ai_ui (AIS-43) and danaview_ai_genkit (AIS-42, only if adopted) are picked up when they
# exist. No test may reach a non-loopback host (AI_STUDIO_PLAN §5.1 rule 4); nothing is downloaded
# beyond pub dependency resolution.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
in_ci="${GITHUB_ACTIONS:-false}"

group() { if [ "$in_ci" = "true" ]; then echo "::group::$1"; else echo "== $1"; fi; }
endgroup() { if [ "$in_ci" = "true" ]; then echo "::endgroup::"; fi; }

# Pure Dart packages first, then Flutter ones.
dart_packages="danaview_ai_providers danaview_ai danaview_ai_genkit"
flutter_packages="danaview_ai_studio danaview_ai_ui"

ran=0
for pkg in $dart_packages; do
  dir="$repo/packages/$pkg"
  [ -f "$dir/pubspec.yaml" ] || { echo "skip $pkg (not created yet)"; continue; }
  group "$pkg (dart)"
  (cd "$dir" && dart pub get && dart analyze --fatal-infos && dart test)
  endgroup
  ran=$((ran + 1))
done
for pkg in $flutter_packages; do
  dir="$repo/packages/$pkg"
  [ -f "$dir/pubspec.yaml" ] || { echo "skip $pkg (not created yet)"; continue; }
  group "$pkg (flutter)"
  (cd "$dir" && flutter pub get && flutter analyze --fatal-infos && flutter test)
  endgroup
  ran=$((ran + 1))
done

if [ "$ran" -lt 2 ]; then
  if [ "$in_ci" = "true" ]; then echo "::error title=ai-dart::danaview_ai_providers and danaview_ai_studio must exist (AIS-01)"; fi
  echo "ai.sh: expected at least danaview_ai_providers and danaview_ai_studio" >&2
  exit 1
fi
