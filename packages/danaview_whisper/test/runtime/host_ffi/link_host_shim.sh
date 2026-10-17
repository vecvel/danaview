#!/usr/bin/env bash
# OWNER: AI-07
#
# Links the host build of the shim (scripts/ci/editor/whisper_host.sh -> build/host-<sanitizer>/)
# into a shared library and writes the download-free fixture model next to it, so
# test/runtime/host_ffi_test.dart can drive the real C ABI through the Dart runtime on macOS/Linux.
#
#   test/runtime/host_ffi/link_host_shim.sh [out_dir] [sanitizer=none]
#   DV_TEST_HOST_LIB=<out>/libdanaview_whisper_host.<dylib|so> \
#   DV_TEST_FIXTURE_MODEL=<out>/fixture-whisper.bin flutter test test/runtime/host_ffi_test.dart
#
# Needs an up-to-date host build (CMake; this script does not build whisper itself).
set -euo pipefail

pkg="$(cd "$(dirname "$0")/../../.." && pwd)"
out="${1:-$pkg/build/host-ffi}"
san="${2:-none}"
build="$pkg/build/host-$san"

if [[ ! -f "$build/libdv_shim.a" || ! -x "$build/tests/dv_tests" ]]; then
  echo "missing $build (run scripts/ci/editor/whisper_host.sh first)" >&2
  exit 2
fi
mkdir -p "$out"

libs=(
  "$build/whisper_cpp/src/libwhisper.a"
  "$build/whisper_cpp/ggml/src/libggml.a"
  "$build/whisper_cpp/ggml/src/libggml-cpu.a"
  "$build/whisper_cpp/ggml/src/libggml-base.a"
)
case "$(uname -s)" in
  Darwin)
    lib="$out/libdanaview_whisper_host.dylib"
    c++ -dynamiclib -o "$lib" -Wl,-force_load,"$build/libdv_shim.a" "${libs[@]}"
    ;;
  *)
    lib="$out/libdanaview_whisper_host.so"
    c++ -shared -o "$lib" -Wl,--whole-archive "$build/libdv_shim.a" -Wl,--no-whole-archive "${libs[@]}" -lpthread
    ;;
esac

# The host tests write the fixture model into a kept temp dir; copy it out.
tmp="$(mktemp -d)"
TMPDIR="$tmp" DV_TEST_KEEP_TMP=1 "$build/tests/dv_tests" Jobs.fixture_transcribes_jfk_deterministically >/dev/null
find "$tmp" -name fixture-whisper.bin -exec cp {} "$out/fixture-whisper.bin" \;
rm -rf "$tmp"
test -f "$out/fixture-whisper.bin"

echo "DV_TEST_HOST_LIB=$lib"
echo "DV_TEST_FIXTURE_MODEL=$out/fixture-whisper.bin"
