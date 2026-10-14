#!/usr/bin/env bash
# OWNER: IOS-09
#
# Prebuilds the Danaview Core Image kernels (DanaviewKernels.metal) into one `-fcikernel` metallib per
# SDK under Prebuilt/, plus BUILD_INFO.txt with the source and output SHA-256 (IOS-01 §3, V-N9,
# ARCH §13.2). The app build never compiles .metal files (Xcode 26 ships no Metal toolchain); run this
# by hand whenever DanaviewKernels.metal changes and commit Prebuilt/.
#
# Needs the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`) or
# DV_METAL_TOOLCHAIN pointing at a mounted Metal.xctoolchain.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/DanaviewKernels.metal"
OUT="$HERE/Prebuilt"
BASE=dv_kernels
MIN_IOS=15.0

if [[ -n "${DV_METAL_TOOLCHAIN:-}" ]]; then
  METAL="$DV_METAL_TOOLCHAIN/usr/bin/metal"
  METALLIB="$DV_METAL_TOOLCHAIN/usr/bin/metallib"
elif xcrun metal --version >/dev/null 2>&1; then
  METAL="xcrun metal"
  METALLIB="xcrun metallib"
else
  echo "No Metal compiler: install the Metal Toolchain component or set DV_METAL_TOOLCHAIN" >&2
  exit 1
fi

mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# -fcikernel records the source path: compile a copy from a neutral folder so the metallibs carry no
# checkout path and are reproducible across machines.
mkdir -p "$TMP/src"
cp "$SRC" "$TMP/src/"
for pair in "iphoneos:air64-apple-ios${MIN_IOS}" "iphonesimulator:air64-apple-ios${MIN_IOS}-simulator"; do
  sdk="${pair%%:*}"
  triple="${pair#*:}"
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  (cd "$TMP/src" && $METAL -c -fcikernel -ffile-prefix-map="$TMP/src"=. -target "$triple" -isysroot "$sysroot" \
    DanaviewKernels.metal -o "$TMP/$BASE.$sdk.air")
  $METALLIB -cikernel "$TMP/$BASE.$sdk.air" -o "$OUT/$BASE.$sdk.metallib"
done
{
  echo "source: $(basename "$SRC")"
  echo "source_sha256: $(shasum -a 256 "$SRC" | cut -d' ' -f1)"
  echo "compiler: $($METAL --version 2>&1 | head -1)"
  echo "flags: metal -c -fcikernel -target air64-apple-ios${MIN_IOS}[-simulator] / metallib -cikernel"
  echo "min_ios: $MIN_IOS"
  for f in "$OUT"/*.metallib; do echo "$(basename "$f"): $(shasum -a 256 "$f" | cut -d' ' -f1)"; done
} > "$OUT/BUILD_INFO.txt"
ls -la "$OUT"
