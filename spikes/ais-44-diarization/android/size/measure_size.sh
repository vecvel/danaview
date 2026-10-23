#!/usr/bin/env bash
# AIS-44 Android half: APK/AAB size added by the stock sherpa_onnx 1.13.8 package.
# Creates two throwaway Flutter apps under build/size_app/ (git-ignored):
#   base   = flutter create template, no extra dependency
#   sherpa = same + sherpa_onnx 1.13.8 and main_sherpa.dart (FFI smoke)
# and builds release APKs split per ABI plus an app bundle for each. Debug-signed.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
ROOT=$PWD/build/size_app
mkdir -p "$ROOT"
for v in base sherpa; do
  if [ ! -d "$ROOT/$v" ]; then
    (cd "$ROOT" && flutter create --org com.vecvel --project-name ais44size \
      --platforms android "$v" >/dev/null)
  fi
done
cp android/size/main_sherpa.dart "$ROOT/sherpa/lib/main.dart"
cp android/size/MainActivity.kt "$ROOT/sherpa/android/app/src/main/kotlin/com/vecvel/ais44size/MainActivity.kt"
grep -q sherpa_onnx "$ROOT/sherpa/pubspec.yaml" || \
  sed -i 's/^dependencies:/dependencies:\n  sherpa_onnx: 1.13.8/' "$ROOT/sherpa/pubspec.yaml"
for v in ${VARIANTS:-base sherpa}; do
  (cd "$ROOT/$v" && flutter pub get >/dev/null && \
   flutter build apk --release --split-per-abi && \
   flutter build appbundle --release)
done
for v in base sherpa; do
  echo "== $v"
  ls -l "$ROOT/$v/build/app/outputs/flutter-apk/"*-release.apk "$ROOT/$v/build/app/outputs/bundle/release/app-release.aab"
done
