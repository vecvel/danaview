#!/usr/bin/env bash
# OWNER: HOM-26
#
# XCTests of danaview_library_native's Quick Look and document thumbnails (BUILD_PLAN HOM-26)
# without the Danaview app, in a throwaway Swift package assembled in a temporary directory from the
# pod sources (documents are generated locally; nothing is downloaded):
#
#   macos          the Flutter-free core (Classes/QuickLook/QuickLookCore.swift with the HOM-04
#                  encoder and the HOM-22 temporary copies it uses: which types Quick Look previews,
#                  editing off, PDF first pages at a scale, password / damaged PDFs, Quick Look
#                  thumbnails) and the QuickLookHostApiImpl / ThumbnailHostApiImpl.documentThumbnail
#                  glue linked against the Flutter SDK's FlutterMacOS.framework with a fake presenter
#                  (read-only copies, Markup can't change the stored file). The real QLPreviewController
#                  and QLPreviewView need a person (device check).
#   ios-typecheck  type-checks every plugin source for the iOS Simulator SDK against Flutter.xcframework
#                  (the QLPreviewController path compiles; no simulator is booted).
#
# The temporary directory is removed on exit. Usage:
#   packages/danaview_library_native/darwin/Tests/QuickLook/run_xctests.sh macos | ios-typecheck
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
darwin="$(cd "$here/../.." && pwd)"
mode="${1:-macos}"

flutter_root="${FLUTTER_ROOT:-$(cd "$(dirname "$(command -v flutter)")/.." && pwd)}"
macos_fw="$flutter_root/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64"
ios_fw="$flutter_root/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"

all_sources=()
while IFS= read -r f; do all_sources+=("$f"); done < <(find "$darwin/Classes" -name '*.swift' | sort)
core_sources=("$darwin/Classes/QuickLook/QuickLookCore.swift" "$darwin/Classes/Thumbnails/ThumbnailCore.swift" "$darwin/Classes/ExportOut/FileOutCore.swift")

if [ "$mode" = "ios-typecheck" ]; then
  [ -d "$ios_fw/Flutter.framework" ] || { echo "Flutter.framework not found under $ios_fw (run flutter precache --ios)" >&2; exit 1; }
  xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios15.0-simulator -F "$ios_fw" \
    -module-name danaview_library_native "${all_sources[@]}"
  echo "iOS type-check passed"
  exit 0
fi

[ "$mode" = "macos" ] || { echo "unknown mode $mode (macos | ios-typecheck)" >&2; exit 2; }
[ -d "$macos_fw/FlutterMacOS.framework" ] || { echo "FlutterMacOS.framework not found under $macos_fw (run flutter precache --macos)" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/dv_quicklook_xctests.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

link_dir() { # <target dir> <source files...>
  local dir="$1"; shift
  mkdir -p "$dir"
  for f in "$@"; do ln -s "$f" "$dir/$(basename "$f")"; done
}

link_dir "$work/Sources/DanaviewQuickLookCore" "${core_sources[@]}"
link_dir "$work/Tests/DanaviewQuickLookCoreTests" "$here"/Core/*.swift
link_dir "$work/Sources/danaview_library_native" "${all_sources[@]}"
link_dir "$work/Tests/QuickLookGlueTests" "$here"/Glue/*.swift "$here/Core/QuickLookTestDocs.swift"
cat > "$work/Package.swift" <<PKG
// swift-tools-version:5.7
import PackageDescription
let fw = "$macos_fw"
let package = Package(
  name: "DanaviewQuickLookTests",
  platforms: [.macOS(.v11)],
  targets: [
    .target(name: "DanaviewQuickLookCore"),
    .testTarget(name: "DanaviewQuickLookCoreTests", dependencies: ["DanaviewQuickLookCore"]),
    .target(name: "danaview_library_native",
            swiftSettings: [.unsafeFlags(["-F", fw])],
            linkerSettings: [.unsafeFlags(["-F", fw, "-framework", "FlutterMacOS", "-Xlinker", "-rpath", "-Xlinker", fw])]),
    .testTarget(name: "QuickLookGlueTests", dependencies: ["danaview_library_native"],
                swiftSettings: [.unsafeFlags(["-F", fw])],
                linkerSettings: [.unsafeFlags(["-F", fw, "-Xlinker", "-rpath", "-Xlinker", fw])]),
  ]
)
PKG
(cd "$work" && swift test -j 2 2>&1) > "$work/test.log" || true
grep -E "Test Case.*(passed|failed|skipped|measured)|error:|Executed" "$work/test.log" || tail -40 "$work/test.log"
if grep -q "with 0 failures" "$work/test.log" && ! grep -q "error:" "$work/test.log"; then exit 0; fi
tail -40 "$work/test.log"
exit 1
