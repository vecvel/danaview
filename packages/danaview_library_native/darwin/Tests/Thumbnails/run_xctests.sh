#!/usr/bin/env bash
# OWNER: HOM-04
#
# XCTests of danaview_library_native's Thumbnails (BUILD_PLAN HOM-04) without the Danaview app,
# assembled in a temporary directory from the pod sources (locally generated media only):
#
#   macos               a throwaway Swift package (`swift test`): the Flutter-free core
#                       (Classes/Thumbnails/ThumbnailCore.swift, PhotoAssetThumbnailer.swift:
#                       geometry, encoder, Quick Look / ImageIO / AVFoundation file path; the
#                       PhotoKit path answers permissionDenied because TCC can't be granted to a
#                       command-line runner) and ThumbnailHostApiImpl linked against the Flutter
#                       SDK's FlutterMacOS.framework.
#   ios-typecheck       type-checks every plugin source for the iOS Simulator SDK against
#                       Flutter.xcframework (no simulator).
#   ios <udid>          the core tests as a hosted XCTest bundle on an already booted iOS
#                       Simulator, reusing the PhotoLibrary test host (Tests/PhotoLibrary/Host/,
#                       bundle id com.vecvel.danaview.librarytests) with photo access granted: the
#                       PHCachingImageManager path end to end, HEIC on iOS 17+, plus the file path.
#
# The temporary directory (and the installed host app) are removed on exit. Usage:
#   packages/danaview_library_native/darwin/Tests/Thumbnails/run_xctests.sh macos | ios-typecheck | ios <udid>
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
darwin="$(cd "$here/../.." && pwd)"
host="$darwin/Tests/PhotoLibrary/Host"
mode="${1:-macos}"
udid="${2:-}"

flutter_root="${FLUTTER_ROOT:-$(cd "$(dirname "$(command -v flutter)")/.." && pwd)}"
macos_fw="$flutter_root/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64"
ios_fw="$flutter_root/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"

all_sources=()
while IFS= read -r f; do all_sources+=("$f"); done < <(find "$darwin/Classes" -name '*.swift' | sort)
core_sources=("$darwin/Classes/Thumbnails/ThumbnailCore.swift" "$darwin/Classes/Thumbnails/PhotoAssetThumbnailer.swift")

if [ "$mode" = "ios-typecheck" ]; then
  [ -d "$ios_fw/Flutter.framework" ] || { echo "Flutter.framework not found under $ios_fw (run flutter precache --ios)" >&2; exit 1; }
  xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios15.0-simulator -F "$ios_fw" \
    -module-name danaview_library_native "${all_sources[@]}"
  echo "iOS type-check passed"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/dv_thumbs_xctests.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

link_dir() { # <target dir> <source files...>
  local dir="$1"; shift
  mkdir -p "$dir"
  for f in "$@"; do ln -s "$f" "$dir/$(basename "$f")"; done
}

if [ "$mode" = "macos" ]; then
  [ -d "$macos_fw/FlutterMacOS.framework" ] || { echo "FlutterMacOS.framework not found under $macos_fw (run flutter precache --macos)" >&2; exit 1; }
  link_dir "$work/Sources/DanaviewThumbnailsCore" "${core_sources[@]}"
  link_dir "$work/Tests/DanaviewThumbnailsCoreTests" "$here"/Core/*.swift
  link_dir "$work/Sources/danaview_library_native" "${all_sources[@]}"
  link_dir "$work/Tests/ThumbnailGlueTests" "$here"/Glue/*.swift "$here/Core/ThumbnailTestMedia.swift"
  cat > "$work/Package.swift" <<EOF
// swift-tools-version:5.7
import PackageDescription
let fw = "$macos_fw"
let package = Package(
  name: "DanaviewThumbnailsTests",
  platforms: [.macOS(.v11)],
  targets: [
    .target(name: "DanaviewThumbnailsCore"),
    .testTarget(name: "DanaviewThumbnailsCoreTests", dependencies: ["DanaviewThumbnailsCore"]),
    .target(name: "danaview_library_native",
            swiftSettings: [.unsafeFlags(["-F", fw])],
            linkerSettings: [.unsafeFlags(["-F", fw, "-framework", "FlutterMacOS", "-Xlinker", "-rpath", "-Xlinker", fw])]),
    .testTarget(name: "ThumbnailGlueTests", dependencies: ["danaview_library_native"],
                swiftSettings: [.unsafeFlags(["-F", fw])],
                linkerSettings: [.unsafeFlags(["-F", fw, "-Xlinker", "-rpath", "-Xlinker", fw])]),
  ]
)
EOF
  (cd "$work" && swift test -j 2 2>&1) > "$work/test.log" || true
  grep -E "Test Case.*(passed|failed|skipped)|error:|Executed|HOM-04 " "$work/test.log" || tail -40 "$work/test.log"
  if grep -q "with 0 failures" "$work/test.log" && ! grep -q "error:" "$work/test.log"; then exit 0; fi
  tail -40 "$work/test.log"
  exit 1
fi

if [ "$mode" = "ios" ]; then
  [ -n "$udid" ] || { echo "usage: $0 ios <booted-simulator-udid>" >&2; exit 2; }
  xcrun simctl list devices booted | grep -q "$udid" || { echo "simulator $udid is not booted" >&2; exit 2; }
  proj="$work/ios"
  mkdir -p "$proj/LibraryTests.xcodeproj/xcshareddata/xcschemes" "$proj/HostApp" "$proj/LibraryTests"
  cp "$host/project.pbxproj" "$proj/LibraryTests.xcodeproj/"
  cp "$host/LibraryTests.xcscheme" "$proj/LibraryTests.xcodeproj/xcshareddata/xcschemes/"
  cp "$host/HostApp.swift" "$proj/HostApp/"
  cp "${core_sources[@]}" "$here"/Core/*.swift "$proj/LibraryTests/"
  common=(-project "$proj/LibraryTests.xcodeproj" -scheme LibraryTests -destination "id=$udid" -derivedDataPath "$work/dd")
  xcodebuild build-for-testing "${common[@]}" > "$work/build.log" 2>&1 || { tail -40 "$work/build.log"; exit 1; }
  app="$(find "$work/dd/Build/Products" -maxdepth 2 -name HostApp.app -type d | head -1)"
  xcrun simctl install "$udid" "$app"
  xcrun simctl privacy "$udid" grant photos com.vecvel.danaview.librarytests
  # As in Tests/PhotoLibrary/run_xctests.sh: Xcode 26's grant writes a version-1 entry that the
  # `.readWrite` query reports as not determined; mark this throwaway host's entry, in this
  # simulator's own TCC store only, as "Allow Full Access".
  tcc_db="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/TCC/TCC.db"
  sqlite3 "$tcc_db" "update access set auth_version = 2 where service = 'kTCCServicePhotos' and client = 'com.vecvel.danaview.librarytests'"
  (xcodebuild test-without-building "${common[@]}" -parallel-testing-enabled NO 2>&1) > "$work/test.log" || true
  grep -E "Test Case.*(passed|failed|skipped)|error:|Executed|TEST (EXECUTE )?(SUCCEEDED|FAILED)" "$work/test.log" || true
  xcrun simctl uninstall "$udid" com.vecvel.danaview.librarytests || true
  if grep -qE "TEST (EXECUTE )?SUCCEEDED" "$work/test.log"; then exit 0; fi
  tail -60 "$work/test.log"
  exit 1
fi

echo "unknown mode $mode (macos | ios-typecheck | ios <udid>)" >&2
exit 2
