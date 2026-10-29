#!/usr/bin/env bash
# OWNER: HOM-24
# EXTENDED: HOM-29 (annotate: Tests/Annotate/Core/ joins the core target with
# Classes/Annotate/PdfAnnotateCore.swift, Tests/Annotate/Glue/ the glue target; ios-sim runs the
# annotate core too.)
# EXTENDED: HOM-28 (the page tools' tests in Tests/Tools/: Core/ joins the core target, Glue/ the glue
# target; the `ios-sim` mode runs the Flutter-free core tests, page tools included, on an iOS
# Simulator: DV_PDF_SIMULATOR names it, default "iPhone 17").
#
# XCTests of danaview_pdf's PDFKit viewer, text and glue (BUILD_PLAN HOM-24) without the Danaview
# app, assembled in a temporary directory from the pod sources (locally generated PDFs plus the
# generated HOM-27 fixtures in spikes/android_pdf/fixtures/; no downloads):
#
#   macos            a throwaway Swift package (`swift test`): the Flutter-free core
#                    (Classes/Viewer/PdfCore.swift, Classes/Text/PdfTextCore.swift) in
#                    Tests/Viewer/Core/, and every plugin source linked against the Flutter SDK's
#                    FlutterMacOS.framework for Tests/Viewer/Glue/ (platform view, host APIs).
#   ios-typecheck    type-checks every plugin source for the iOS Simulator SDK against
#                    Flutter.xcframework (no simulator).
#   ios-sim          the Flutter-free core tests (viewer core, text core, page tools) as a Swift
#                    package on the iOS Simulator named by DV_PDF_SIMULATOR (xcodebuild test).
#
# The temporary directory is removed on exit. Usage:
#   packages/danaview_pdf/darwin/Tests/Viewer/run_xctests.sh macos | ios-typecheck | ios-sim
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
darwin="$(cd "$here/../.." && pwd)"
repo="$(cd "$darwin/../../.." && pwd)"
mode="${1:-macos}"

flutter_root="${FLUTTER_ROOT:-$(cd "$(dirname "$(command -v flutter)")/.." && pwd)}"
macos_fw="$flutter_root/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64"
ios_fw="$flutter_root/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"

all_sources=()
while IFS= read -r f; do all_sources+=("$f"); done < <(find "$darwin/Classes" -name '*.swift' | sort)
core_sources=("$darwin/Classes/Viewer/PdfCore.swift" "$darwin/Classes/Text/PdfTextCore.swift" "$darwin/Classes/Tools/PdfPageToolsCore.swift"
  "$darwin/Classes/Annotate/PdfAnnotateCore.swift")
tools="$darwin/Tests/Tools"
annotate="$darwin/Tests/Annotate"
core_tests=("$here"/Core/*.swift "$tools"/Core/*.swift "$annotate"/Core/*.swift)
glue_tests=("$here"/Glue/*.swift "$tools"/Glue/*.swift "$annotate"/Glue/*.swift)

if [ "$mode" = "ios-typecheck" ]; then
  [ -d "$ios_fw/Flutter.framework" ] || { echo "Flutter.framework not found under $ios_fw (run flutter precache --ios)" >&2; exit 1; }
  xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios15.0-simulator -F "$ios_fw" \
    -module-name danaview_pdf "${all_sources[@]}"
  echo "iOS type-check passed"
  exit 0
fi

if [ "$mode" = "ios-sim" ]; then
  simulator="${DV_PDF_SIMULATOR:-iPhone 17}"
  work="$(mktemp -d "${TMPDIR:-/tmp}/dv_pdf_ios_xctests.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  mkdir -p "$work/Sources/DanaviewPdfCore" "$work/Tests/DanaviewPdfCoreTests"
  for f in "${core_sources[@]}"; do cp "$f" "$work/Sources/DanaviewPdfCore/"; done
  for f in "${core_tests[@]}"; do
    { echo "@testable import DanaviewPdfCore"; cat "$f"; } > "$work/Tests/DanaviewPdfCoreTests/$(basename "$f")"
  done
  cat > "$work/Package.swift" <<'PKG'
// swift-tools-version:5.7
import PackageDescription
let package = Package(
  name: "DanaviewPdfCore",
  platforms: [.macOS(.v11), .iOS(.v15)],
  products: [.library(name: "DanaviewPdfCore", targets: ["DanaviewPdfCore"])],
  targets: [
    .target(name: "DanaviewPdfCore"),
    .testTarget(name: "DanaviewPdfCoreTests", dependencies: ["DanaviewPdfCore"]),
  ]
)
PKG
  # The copied tests can't find the fixtures by walking up from #filePath; the runner passes the
  # TEST_RUNNER_-prefixed variable into the simulator's test process (it reads host paths).
  export TEST_RUNNER_DV_PDF_FIXTURES="$repo/spikes/android_pdf/fixtures"
  (cd "$work" && xcodebuild test -scheme DanaviewPdfCore -destination "platform=iOS Simulator,name=$simulator" \
    -derivedDataPath "$work/dd" 2>&1) > "$work/test.log" || true
  grep -E "Test Case.*(passed|failed|skipped)|error:|Executed|TEST (SUCCEEDED|FAILED)" "$work/test.log" || tail -40 "$work/test.log"
  if grep -q "TEST SUCCEEDED" "$work/test.log"; then exit 0; fi
  tail -60 "$work/test.log"
  exit 1
fi

if [ "$mode" != "macos" ]; then
  echo "unknown mode $mode (macos | ios-typecheck | ios-sim)" >&2
  exit 2
fi

[ -d "$macos_fw/FlutterMacOS.framework" ] || { echo "FlutterMacOS.framework not found under $macos_fw (run flutter precache --macos)" >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/dv_pdf_xctests.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

link_dir() { # <target dir> <source files...>
  local dir="$1"; shift
  mkdir -p "$dir"
  for f in "$@"; do ln -s "$f" "$dir/$(basename "$f")"; done
}

link_dir "$work/Sources/DanaviewPdfCore" "${core_sources[@]}"
link_dir "$work/Tests/DanaviewPdfCoreTests" "${core_tests[@]}"
link_dir "$work/Sources/danaview_pdf" "${all_sources[@]}"
link_dir "$work/Tests/PdfGlueTests" "${glue_tests[@]}" "$here/Core/TestPdfs.swift" \
  "$here"/../Compress/Glue/*.swift "$here/../Compress/CompressFixtures.swift"
cat > "$work/Package.swift" <<PKG
// swift-tools-version:5.7
import PackageDescription
let fw = "$macos_fw"
let package = Package(
  name: "DanaviewPdfTests",
  platforms: [.macOS(.v11)],
  targets: [
    .target(name: "DanaviewPdfCore"),
    .testTarget(name: "DanaviewPdfCoreTests", dependencies: ["DanaviewPdfCore"]),
    .target(name: "danaview_pdf",
            swiftSettings: [.unsafeFlags(["-F", fw])],
            linkerSettings: [.unsafeFlags(["-F", fw, "-framework", "FlutterMacOS", "-Xlinker", "-rpath", "-Xlinker", fw])]),
    .testTarget(name: "PdfGlueTests", dependencies: ["danaview_pdf"],
                swiftSettings: [.unsafeFlags(["-F", fw])],
                linkerSettings: [.unsafeFlags(["-F", fw, "-Xlinker", "-rpath", "-Xlinker", fw])]),
  ]
)
PKG
# The core tests use the core's internal types: prepend `@testable import DanaviewPdfCore`.
for f in "${core_tests[@]}"; do
  rm "$work/Tests/DanaviewPdfCoreTests/$(basename "$f")"
  { echo "@testable import DanaviewPdfCore"; cat "$f"; } > "$work/Tests/DanaviewPdfCoreTests/$(basename "$f")"
done
export DV_PDF_FIXTURES="$repo/spikes/android_pdf/fixtures"
(cd "$work" && swift test -j 2 2>&1) > "$work/test.log" || true
grep -E "Test Case.*(passed|failed|skipped)|error:|Executed" "$work/test.log" || tail -40 "$work/test.log"
if grep -q "with 0 failures" "$work/test.log" && ! grep -q "error:" "$work/test.log"; then exit 0; fi
tail -40 "$work/test.log"
exit 1
