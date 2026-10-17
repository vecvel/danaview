#!/usr/bin/env bash
# OWNER: AI-05
#
# Builds ios/Frameworks/WhisperCore.xcframework: the vendored whisper.cpp v1.9.4 + ggml as ONE static
# library per slice (ai.md §4.4, ARCH D-29/D-41, BUILD_PLAN AI-05).
#
#   slices        ios-arm64 (iphoneos) and ios-arm64_x86_64-simulator (lipo of two builds)
#   deployment    IPHONEOS_DEPLOYMENT_TARGET 15.0 (DV_IOS_MIN may raise it, never lower it)
#   backends      ggml-cpu (NEON on arm64) + ggml-metal with the EMBEDDED Metal library. The shim only
#                 asks for the GPU on iOS >= 16.4 with Apple GPU family >= 6 (src/dv_cpu.cpp).
#                 Accelerate and BLAS are OFF: ggml would bind Apple's NEWLAPACK interface (iOS 16.4+)
#                 strongly, and the framework loads at app launch on iOS 15.
#   flags         -fvisibility=hidden (only the pod's dv_* entry points are exported) and
#                 -Werror=unguarded-availability-new (every post-15.0 API must sit behind @available).
#   checks        after the build: no NEWLAPACK / Accelerate symbols (`nm -um`), and when present
#                 scripts/ci/editor/check_ios_min_os.sh (ENG-09) on the xcframework (V-A1).
#
# The framework is git-ignored (packages/danaview_whisper/.gitignore). A stamp file next to it
# (ios/Frameworks/WhisperCore.stamp) records the whisper commit, the vendored tree digest, this
# script's sha256, the deployment target and `xcodebuild -version`; --if-missing is a fast no-op when
# the stamp matches, so CI (scripts/ci/editor/ios.sh) and the release lane can call it on every run.
#
# Usage:
#   tool/build_ios_xcframework.sh               rebuild unconditionally
#   tool/build_ios_xcframework.sh --if-missing  build only when the framework is missing or stale
#   tool/build_ios_xcframework.sh --status      print up-to-date | stale | missing (exit 0 | 3 | 4)
#   tool/build_ios_xcframework.sh --clean       delete the framework, stamp and build tree, then exit
#   options: --jobs N (default: min(4, cores/2)), --keep-build (keep build/ios-xcframework),
#            --no-check (skip the post-build symbol/min-OS checks; not for CI)
#
# Environment:
#   DV_CMAKE              path to cmake (default: newest of PATH, Homebrew, CMake.app, Android SDK)
#   DV_ALLOW_OLD_CMAKE=1  accept CMake 3.22..3.27 (verified with the Android SDK's 3.22.1 + Ninja on
#                         the dev Mac). CI and release builds use CMake >= 3.28 (brew install cmake).
#   DV_IOS_MIN            deployment target (default 15.0; lower values are rejected)
#
# Requirements: Xcode command line tools (xcrun, clang, libtool, lipo, xcodebuild), CMake >= 3.28,
# and Ninja or make. Nothing is downloaded: whisper.cpp is vendored in third_party/ (AI-01).
# bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PKG="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
ROOT="$(cd "$PKG/../.." && pwd)"
SRC="$PKG/third_party/whisper.cpp"
VENDORED_MD="$PKG/third_party/VENDORED.md"
OUT_DIR="$PKG/ios/Frameworks"
OUT="$OUT_DIR/WhisperCore.xcframework"
STAMP="$OUT_DIR/WhisperCore.stamp"
BUILD="$PKG/build/ios-xcframework"
MIN_OS_CHECK="$ROOT/scripts/ci/editor/check_ios_min_os.sh"
FLOOR="15.0"
CMAKE_REQUIRED="3.28"
CMAKE_OLDEST="3.22"

MODE=build
JOBS=""
KEEP_BUILD=false
RUN_CHECKS=true
while [ $# -gt 0 ]; do
  case "$1" in
    --if-missing) MODE=if-missing ;;
    --status) MODE=status ;;
    --clean) MODE=clean ;;
    --jobs) shift; JOBS="${1:-}" ;;
    --jobs=*) JOBS="${1#--jobs=}" ;;
    --keep-build) KEEP_BUILD=true ;;
    --no-check) RUN_CHECKS=false ;;
    -h | --help) sed -n '2,40p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build_ios_xcframework.sh: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[whisper-ios] $*"; }
die() { echo "[whisper-ios] error: $*" >&2; exit 1; }

# version_ge A B: A >= B (numeric, up to three components).
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, A, "."); nb = split(b, B, ".");
    for (i = 1; i <= 3; i++) { x = (i <= na) ? A[i] + 0 : 0; y = (i <= nb) ? B[i] + 0 : 0;
      if (x > y) exit 0; if (x < y) exit 1 }
    exit 0 }'
}

IOS_MIN="${DV_IOS_MIN:-$FLOOR}"
version_ge "$IOS_MIN" "$FLOOR" || die "DV_IOS_MIN=$IOS_MIN is below the app's iOS floor $FLOOR (ARCH D-29)"

# --- Stamp ------------------------------------------------------------------------------------------

# The tree digest is computed the way VENDORED.md defines it, so a changed vendored file (which AI-01
# forbids) also invalidates the framework. Only files git does not ignore count: whisper.cpp's CMake
# configure writes git-ignored files into the source tree (bindings/javascript/package.json), and
# those must not make the vendored tree look edited (FIX-AI-05-1). Paths keep the "./" prefix so the
# lines match VENDORED.md's `find .` definition. Outside a git checkout every file counts.
tree_files() {
  if git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$SRC" ls-files -z --cached --others --exclude-standard -- . |
      while IFS= read -r -d '' f; do [ -f "$SRC/$f" ] && printf './%s\0' "$f"; done
  else
    (cd "$SRC" && find . -type f -print0)
  fi
}
tree_digest() {
  (cd "$SRC" && tree_files | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{ print $1 }')
}

vendored_digest() {
  sed -n 's/^| Tree digest | `\([0-9a-f]*\)` |$/\1/p' "$VENDORED_MD" | head -n 1
}

whisper_commit() {
  sed -n 's/^| Commit | `\([0-9a-f]*\)` |$/\1/p' "$VENDORED_MD" | head -n 1
}

expected_stamp() {
  command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found: install Xcode (scripts/ci/editor/README.md)"
  echo "format=1"
  echo "whisper_commit=$(whisper_commit)"
  echo "whisper_tree=$(tree_digest)"
  echo "script_sha256=$(shasum -a 256 "$SCRIPT_PATH" | awk '{ print $1 }')"
  echo "ios_min=$IOS_MIN"
  echo "xcode=$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
}

# up-to-date | stale | missing
status() {
  if [ ! -f "$OUT/Info.plist" ]; then echo missing; return; fi
  if [ ! -f "$STAMP" ]; then echo stale; return; fi
  # Lines after "--" in the stamp are informational (cmake version, sizes) and not compared.
  if [ "$(sed '/^--$/,$d' "$STAMP")" = "$(expected_stamp)" ]; then echo up-to-date; else echo stale; fi
}

case "$MODE" in
  clean)
    rm -rf "$OUT" "$STAMP" "$BUILD"
    log "removed WhisperCore.xcframework, its stamp and build/ios-xcframework"
    exit 0
    ;;
  status)
    s="$(status)"
    echo "$s"
    case "$s" in up-to-date) exit 0 ;; stale) exit 3 ;; *) exit 4 ;; esac
    ;;
  if-missing)
    s="$(status)"
    if [ "$s" = up-to-date ]; then
      log "WhisperCore.xcframework is up to date (stamp matches); nothing to do"
      exit 0
    fi
    log "WhisperCore.xcframework is $s; building"
    ;;
esac

# --- Toolchain ----------------------------------------------------------------------------------------

[ "$(uname -s)" = Darwin ] || die "the iOS framework can only be built on macOS with Xcode"
for t in xcrun xcodebuild libtool lipo nm shasum; do
  command -v "$t" >/dev/null 2>&1 || die "$t not found: install Xcode and its command line tools"
done
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || die "the iphoneos SDK is missing (xcode-select -s /Applications/Xcode.app)"
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1 || die "the iphonesimulator SDK is missing"
[ -f "$SRC/CMakeLists.txt" ] || die "vendored whisper.cpp not found at third_party/whisper.cpp (AI-01)"
[ -n "$(whisper_commit)" ] || die "cannot read the whisper commit from third_party/VENDORED.md"
TREE_NOW="$(tree_digest)"
if [ "$TREE_NOW" != "$(vendored_digest)" ]; then
  die "third_party/whisper.cpp differs from VENDORED.md (tree digest $TREE_NOW, expected $(vendored_digest)); vendored sources are never edited by hand: re-run tool/vendor_whisper.sh or restore them"
fi

cmake_version() { "$1" --version 2>/dev/null | sed -n 1p | awk '{ print $3 }' | sed 's/-.*//'; }

CMAKE=""
CMAKE_V=""
consider_cmake() {
  local c="$1" v
  [ -n "$c" ] && [ -x "$c" ] || return 0
  v="$(cmake_version "$c")"
  [ -n "$v" ] || return 0
  if [ -z "$CMAKE" ] || ! version_ge "$CMAKE_V" "$v"; then CMAKE="$c"; CMAKE_V="$v"; fi
}
if [ -n "${DV_CMAKE:-}" ]; then
  [ -x "$DV_CMAKE" ] || die "DV_CMAKE=$DV_CMAKE is not executable"
  CMAKE="$DV_CMAKE"; CMAKE_V="$(cmake_version "$DV_CMAKE")"
else
  consider_cmake "$(command -v cmake 2>/dev/null || true)"
  consider_cmake /opt/homebrew/bin/cmake
  consider_cmake /usr/local/bin/cmake
  consider_cmake /Applications/CMake.app/Contents/bin/cmake
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk"; do
    [ -n "$sdk" ] && [ -d "$sdk/cmake" ] || continue
    for c in "$sdk"/cmake/*/bin/cmake; do consider_cmake "$c"; done
  done
fi
INSTALL_HINT="Install it with: brew install cmake (or point DV_CMAKE at a CMake >= $CMAKE_REQUIRED)"
[ -n "$CMAKE" ] || die "CMake >= $CMAKE_REQUIRED is required to build WhisperCore.xcframework. $INSTALL_HINT"
if ! version_ge "$CMAKE_V" "$CMAKE_REQUIRED"; then
  if [ "${DV_ALLOW_OLD_CMAKE:-}" = 1 ] && version_ge "$CMAKE_V" "$CMAKE_OLDEST"; then
    log "warning: using CMake $CMAKE_V ($CMAKE) because DV_ALLOW_OLD_CMAKE=1; CI uses >= $CMAKE_REQUIRED"
  else
    die "CMake $CMAKE_V ($CMAKE) is too old: >= $CMAKE_REQUIRED is required. $INSTALL_HINT (local only: DV_ALLOW_OLD_CMAKE=1 accepts >= $CMAKE_OLDEST)"
  fi
fi

GENERATOR_ARGS=()
NINJA=""
for n in "$(dirname "$CMAKE")/ninja" "$(command -v ninja 2>/dev/null || true)" /opt/homebrew/bin/ninja /usr/local/bin/ninja; do
  if [ -n "$n" ] && [ -x "$n" ]; then NINJA="$n"; break; fi
done
if [ -n "$NINJA" ]; then
  GENERATOR_ARGS=(-G Ninja "-DCMAKE_MAKE_PROGRAM=$NINJA")
else
  command -v make >/dev/null 2>&1 || die "neither ninja nor make found"
  GENERATOR_ARGS=(-G "Unix Makefiles")
fi

if [ -z "$JOBS" ]; then
  cores="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  JOBS=$(( cores / 2 )); [ "$JOBS" -ge 1 ] || JOBS=1; [ "$JOBS" -le 4 ] || JOBS=4
fi
case "$JOBS" in '' | *[!0-9]*) die "--jobs needs a positive number" ;; esac

log "cmake $CMAKE_V ($CMAKE), generator ${GENERATOR_ARGS[1]}, $JOBS jobs, iOS $IOS_MIN"
log "whisper.cpp $(whisper_commit)"

# One build at a time (two CI steps or a dev shell racing would clobber each other's build tree).
mkdir -p "$PKG/build"
LOCK="$PKG/build/.ios-xcframework.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  die "another build_ios_xcframework.sh is running (remove $LOCK if it was interrupted)"
fi
cleanup() {
  rmdir "$LOCK" 2>/dev/null || true
  if [ "$KEEP_BUILD" != true ]; then rm -rf "$BUILD"; fi
}
trap cleanup EXIT

rm -rf "$BUILD"
mkdir -p "$BUILD"

# --- Per-slice builds -----------------------------------------------------------------------------------

# whisper.cpp is configured through a generated wrapper project (add_subdirectory), like the host
# build in src/CMakeLists.txt: as the top-level project upstream would write
# bindings/javascript/package.json into the vendored tree and run git there.
WRAPPER="$BUILD/wrapper"
mkdir -p "$WRAPPER"
cat >"$WRAPPER/CMakeLists.txt" <<CMAKE
# Generated by tool/build_ios_xcframework.sh; do not edit.
cmake_minimum_required(VERSION 3.14)
project(WhisperCoreIOS C CXX)
add_subdirectory("$SRC" whisper_cpp)
CMAKE

COMMON_FLAGS="-fvisibility=hidden -Werror=unguarded-availability-new -Werror=unguarded-availability"

# build_slice NAME SDK ARCH PROCESSOR -> $BUILD/NAME/libWhisperCore.a
build_slice() {
  local name="$1" sdk="$2" arch="$3" proc="$4"
  local dir="$BUILD/$name"
  log "configure $name ($sdk $arch)"
  "$CMAKE" -S "$WRAPPER" -B "$dir/cmake" "${GENERATOR_ARGS[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    "-DCMAKE_OSX_SYSROOT=$sdk" \
    "-DCMAKE_OSX_ARCHITECTURES=$arch" \
    "-DCMAKE_SYSTEM_PROCESSOR=$proc" \
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN" \
    -DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_IS_DEV=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_CURL=OFF -DWHISPER_SDL2=OFF -DWHISPER_COREML=OFF -DWHISPER_OPENVINO=OFF \
    -DWHISPER_ALL_WARNINGS=OFF \
    -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_CPU_KLEIDIAI=OFF -DGGML_BACKEND_DL=OFF -DGGML_CCACHE=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_METAL_NDEBUG=ON \
    -DGGML_BLAS=OFF -DGGML_ACCELERATE=OFF \
    "-DCMAKE_C_FLAGS=$COMMON_FLAGS" \
    "-DCMAKE_CXX_FLAGS=$COMMON_FLAGS" \
    "-DCMAKE_OBJC_FLAGS=$COMMON_FLAGS" \
    "-DCMAKE_OBJCXX_FLAGS=$COMMON_FLAGS" \
    >"$dir.configure.log" 2>&1 || { tail -n 40 "$dir.configure.log" >&2; die "CMake configure failed for $name (log above)"; }
  # The configure log must show the backends we asked for; a silent fallback would ship the wrong thing.
  grep -q "Including METAL backend" "$dir.configure.log" || die "$name: ggml did not enable the Metal backend"
  if grep -q "Including BLAS backend" "$dir.configure.log"; then die "$name: ggml enabled BLAS"; fi
  log "build $name"
  "$CMAKE" --build "$dir/cmake" --config Release --target whisper --parallel "$JOBS" \
    >"$dir.build.log" 2>&1 || { grep -E "error|Error" "$dir.build.log" | head -n 40 >&2; die "build failed for $name ($dir.build.log)"; }
  local libs
  libs="$(find "$dir/cmake" -name 'lib*.a' -type f | LC_ALL=C sort)"
  [ -n "$libs" ] || die "$name: no static libraries were produced"
  for want in libwhisper.a libggml.a libggml-base.a libggml-cpu.a libggml-metal.a; do
    echo "$libs" | grep -q "/$want\$" || die "$name: $want missing from the build"
  done
  # Several ggml objects share a file name (e.g. quants.c.o); libtool keeps all of them (ld resolves
  # members by the archive's symbol table), so its "same member name" warning is expected.
  # shellcheck disable=SC2086
  libtool -static -no_warning_for_no_symbols -o "$dir/libWhisperCore.a" $libs 2>"$dir.libtool.log" \
    || { cat "$dir.libtool.log" >&2; die "libtool failed for $name"; }
}

build_slice device-arm64 iphoneos arm64 aarch64
build_slice simulator-arm64 iphonesimulator arm64 aarch64
build_slice simulator-x86_64 iphonesimulator x86_64 x86_64

mkdir -p "$BUILD/simulator"
lipo -create "$BUILD/simulator-arm64/libWhisperCore.a" "$BUILD/simulator-x86_64/libWhisperCore.a" \
  -output "$BUILD/simulator/libWhisperCore.a"

# Public headers: whisper.h + ggml's (the pod's forwarder compiles against the same vendored headers).
HDR="$BUILD/Headers"
mkdir -p "$HDR"
cp "$SRC/include/whisper.h" "$HDR/"
cp "$SRC"/ggml/include/*.h "$HDR/"

STAGE="$BUILD/xcframework"
rm -rf "$STAGE"
mkdir -p "$STAGE"
xcodebuild -create-xcframework \
  -library "$BUILD/device-arm64/libWhisperCore.a" -headers "$HDR" \
  -library "$BUILD/simulator/libWhisperCore.a" -headers "$HDR" \
  -output "$STAGE/WhisperCore.xcframework" >"$BUILD/xcframework.log" 2>&1 \
  || { cat "$BUILD/xcframework.log" >&2; die "xcodebuild -create-xcframework failed"; }

# --- Checks (V-A1) ---------------------------------------------------------------------------------------

if [ "$RUN_CHECKS" = true ]; then
  for lib in "$BUILD/device-arm64/libWhisperCore.a" "$BUILD/simulator/libWhisperCore.a"; do
    undefined="$(nm -um "$lib" 2>/dev/null || true)"
    if echo "$undefined" | grep -q 'NEWLAPACK'; then
      die "$(basename "$(dirname "$lib")"): NEWLAPACK symbols are referenced (Accelerate's iOS 16.4 interface)"
    fi
    if echo "$undefined" | grep -Eq '_(cblas|vDSP|vv|dgemm|sgemm)_?[A-Za-z0-9_]*$'; then
      die "$(basename "$(dirname "$lib")"): Accelerate/BLAS symbols are referenced (GGML_ACCELERATE/GGML_BLAS must be OFF)"
    fi
  done
  log "nm -um: no NEWLAPACK or Accelerate/BLAS references"
  if [ -f "$MIN_OS_CHECK" ]; then
    log "check_ios_min_os.sh --min $FLOOR (ENG-09, D-41)"
    bash "$MIN_OS_CHECK" --min "$FLOOR" "$STAGE/WhisperCore.xcframework" \
      || die "check_ios_min_os.sh found symbols or load commands above iOS $FLOOR"
  else
    log "note: scripts/ci/editor/check_ios_min_os.sh not found; min-OS check skipped"
  fi
fi

# --- Install atomically + stamp ------------------------------------------------------------------------

mkdir -p "$OUT_DIR"
rm -rf "$OUT.old"
if [ -d "$OUT" ]; then mv "$OUT" "$OUT.old"; fi
mv "$STAGE/WhisperCore.xcframework" "$OUT"
rm -rf "$OUT.old"
{
  expected_stamp
  echo "--"
  echo "cmake=$CMAKE_V"
  echo "device_arm64_bytes=$(stat -f %z "$BUILD/device-arm64/libWhisperCore.a")"
  echo "simulator_bytes=$(stat -f %z "$BUILD/simulator/libWhisperCore.a")"
} >"$STAMP"

log "built $(cd "$PKG" && echo ios/Frameworks/WhisperCore.xcframework) ($(du -sh "$OUT" | awk '{ print $1 }'))"
