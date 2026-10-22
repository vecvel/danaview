#!/usr/bin/env bash
# OWNER: HOM-20
#
# XCTests of danaview_library_native's Pickers (BUILD_PLAN HOM-20) without the Danaview app, in a
# throwaway Swift package assembled in a temporary directory from the pod sources:
#
#   macos    the Flutter-free picker core (Classes/Pickers/PickerCore.swift: result mapping,
#            naming, staging, the streamed resumable copy) and the PickerHostApiImpl glue linked
#            against the Flutter SDK's FlutterMacOS.framework (message mapping, copyToFile through
#            the Pigeon API). The pickers' own UI needs a person (device check).
#   ios      type-checks every plugin source for the iOS Simulator SDK against Flutter.xcframework
#            (the PHPicker and UIDocumentPicker paths compile; no simulator is booted).
#
# The temporary directory is removed on exit. Usage:
#   packages/danaview_library_native/darwin/Tests/Pickers/run_xctests.sh macos|ios
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
darwin="$(cd "$here/../.." && pwd)"
mode="${1:-macos}"

flutter_root="${FLUTTER_ROOT:-$(cd "$(dirname "$(command -v flutter)")/.." && pwd)}"
macos_fw="$flutter_root/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64"
ios_fw="$flutter_root/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"

all_sources=()
while IFS= read -r f; do all_sources+=("$f"); done < <(find "$darwin/Classes" -name '*.swift' | sort)

if [ "$mode" = "ios" ]; then
  [ -d "$ios_fw/Flutter.framework" ] || { echo "Flutter.framework not found under $ios_fw (run flutter precache --ios)" >&2; exit 1; }
  xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios15.0-simulator -F "$ios_fw" \
    -module-name danaview_library_native "${all_sources[@]}"
  echo "iOS type-check passed"
  exit 0
fi

[ "$mode" = "macos" ] || { echo "unknown mode $mode (macos | ios)" >&2; exit 2; }
[ -d "$macos_fw/FlutterMacOS.framework" ] || { echo "FlutterMacOS.framework not found under $macos_fw (run flutter precache --macos)" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/dv_pickers_xctests.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

link_dir() { # <target dir> <source files...>
  local dir="$1"; shift
  mkdir -p "$dir"
  for f in "$@"; do ln -s "$f" "$dir/$(basename "$f")"; done
}

link_dir "$work/Sources/DanaviewPickersCore" "$darwin/Classes/Pickers/PickerCore.swift"
link_dir "$work/Tests/DanaviewPickersCoreTests" "$here"/Core/*.swift
link_dir "$work/Sources/danaview_library_native" "${all_sources[@]}"
link_dir "$work/Tests/PickerGlueTests" "$here"/Glue/*.swift
cat > "$work/Package.swift" <<EOF
// swift-tools-version:5.7
import PackageDescription
let fw = "$macos_fw"
let package = Package(
  name: "DanaviewPickersTests",
  platforms: [.macOS(.v11)],
  targets: [
    .target(name: "DanaviewPickersCore"),
    .testTarget(name: "DanaviewPickersCoreTests", dependencies: ["DanaviewPickersCore"]),
    .target(name: "danaview_library_native",
            swiftSettings: [.unsafeFlags(["-F", fw])],
            linkerSettings: [.unsafeFlags(["-F", fw, "-framework", "FlutterMacOS", "-Xlinker", "-rpath", "-Xlinker", fw])]),
    .testTarget(name: "PickerGlueTests", dependencies: ["danaview_library_native"],
                swiftSettings: [.unsafeFlags(["-F", fw])],
                linkerSettings: [.unsafeFlags(["-F", fw, "-Xlinker", "-rpath", "-Xlinker", fw])]),
  ]
)
EOF
(cd "$work" && swift test 2>&1) > "$work/test.log" || true
grep -E "Test Case.*(passed|failed|skipped)|error:|Executed" "$work/test.log" || tail -40 "$work/test.log"
if grep -q "with 0 failures" "$work/test.log" && ! grep -q "error:" "$work/test.log"; then exit 0; fi
tail -40 "$work/test.log"
exit 1
