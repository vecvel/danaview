#!/usr/bin/env bash
# Build diarize_probe for one Android ABI with the NDK, linking the sherpa-onnx
# .so files shipped in the sherpa_onnx_android_* 1.13.8 pub packages.
# Needs build/android/include/sherpa-onnx/c-api/c-api.h (sherpa-onnx tag v1.13.8,
# fetched by fetch_header.sh). Output: build/android/<abi>/ (git-ignored).
set -euo pipefail
cd "$(dirname "$0")/../.."
ABI=${1:-x86_64}
case $ABI in
  x86_64) T=x86_64-linux-android24; P=x86_64 ;;
  arm64-v8a) T=aarch64-linux-android24; P=arm64 ;;
  *) echo "abi?"; exit 2 ;;
esac
NDK=${ANDROID_NDK:-$ANDROID_HOME/ndk/28.2.13676358}
CC=$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin/clang
[ -x "$CC" ] || CC=$CC.exe
PUB=${PUB_CACHE:-$(cygpath -u "$LOCALAPPDATA")/Pub/Cache}/hosted/pub.dev
LIBS=$PUB/sherpa_onnx_android_$P-1.13.8/android/src/main/jniLibs/$ABI
OUT=build/android/$ABI
mkdir -p "$OUT"
cp "$LIBS"/*.so "$OUT"/
"$CC" --target=$T -O2 -Ibuild/android/include android/probe/diarize_probe.c \
  -L"$OUT" -lsherpa-onnx-c-api -o "$OUT/diarize_probe"
ls -l "$OUT"
