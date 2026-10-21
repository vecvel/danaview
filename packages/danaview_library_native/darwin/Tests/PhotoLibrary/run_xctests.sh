#!/usr/bin/env bash
# OWNER: HOM-02
#
# XCTests of danaview_library_native's PhotoLibrary and Glue (BUILD_PLAN HOM-02) without an app
# host: builds a throwaway Swift package in a temporary directory whose targets symlink the pod
# sources, then runs
#
#   macos                 swift test on this Mac: the pure helpers, the Glue (linked against the
#                         Flutter SDK's FlutterMacOS.framework: every placeholder answers
#                         notSupportedOnDevice, backup flag, conversions). PhotoKit tests skip
#                         (TCC can't be granted to a command-line test runner).
#   ios <simulator-udid>  xcodebuild test of the Flutter-free PhotoLibrary core on an already
#                         booted iOS Simulator, after seeding its library with `xcrun simctl
#                         addmedia` (seed_media.swift; local media only) and granting photo access
#                         to the test runner: paging, change events on add and delete, limited and
#                         denied access, EXIF, create-new copies.
#
# The temporary package is deleted on exit. Usage:
#   packages/danaview_library_native/darwin/Tests/PhotoLibrary/run_xctests.sh macos
#   packages/danaview_library_native/darwin/Tests/PhotoLibrary/run_xctests.sh ios <udid> [--no-seed]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
darwin="$(cd "$here/../.." && pwd)"
mode="${1:-macos}"
udid="${2:-}"
seed=true
[ "${3:-}" = "--no-seed" ] && seed=false

flutter_root="${FLUTTER_ROOT:-$(cd "$(dirname "$(command -v flutter)")/.." && pwd)}"
macos_fw="$flutter_root/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64"

work="$(mktemp -d "${TMPDIR:-/tmp}/dv_library_xctests.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

link_dir() { # <target dir> <source files...>
  local dir="$1"; shift
  mkdir -p "$dir"
  for f in "$@"; do ln -s "$f" "$dir/$(basename "$f")"; done
}

core_sources=("$darwin"/Classes/PhotoLibrary/*.swift)
link_dir "$work/Sources/DanaviewPhotoLibraryCore" "${core_sources[@]}"
link_dir "$work/Tests/DanaviewPhotoLibraryCoreTests" "$here"/Core/*.swift

if [ "$mode" = "macos" ]; then
  [ -d "$macos_fw/FlutterMacOS.framework" ] || { echo "FlutterMacOS.framework not found under $macos_fw (run flutter precache --macos)" >&2; exit 1; }
  link_dir "$work/Sources/danaview_library_native" $(find "$darwin/Classes" -name '*.swift' | sort)
  link_dir "$work/Tests/LibraryGlueTests" "$here"/Glue/*.swift
  cat > "$work/Package.swift" <<EOF
// swift-tools-version:5.7
import PackageDescription
let fw = "$macos_fw"
let package = Package(
  name: "DanaviewLibraryNativeTests",
  platforms: [.macOS(.v11)],
  targets: [
    .target(name: "DanaviewPhotoLibraryCore"),
    .testTarget(name: "DanaviewPhotoLibraryCoreTests", dependencies: ["DanaviewPhotoLibraryCore"]),
    .target(name: "danaview_library_native",
            swiftSettings: [.unsafeFlags(["-F", fw])],
            linkerSettings: [.unsafeFlags(["-F", fw, "-framework", "FlutterMacOS", "-Xlinker", "-rpath", "-Xlinker", fw])]),
    .testTarget(name: "LibraryGlueTests", dependencies: ["danaview_library_native"],
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
fi

if [ "$mode" = "ios" ]; then
  [ -n "$udid" ] || { echo "usage: $0 ios <booted-simulator-udid> [--no-seed]" >&2; exit 2; }
  xcrun simctl list devices booted | grep -q "$udid" || { echo "simulator $udid is not booted" >&2; exit 2; }
  if $seed; then
    xcrun swift "$here/seed_media.swift" "$work/seed" >/dev/null
    xcrun simctl addmedia "$udid" "$work"/seed/*
  fi
  # A hosted unit-test bundle (Host/: an empty app with the photo usage strings), so TCC has a
  # bundle identity to grant photo access to; the bundle compiles the PhotoLibrary core and tests
  # as one module. Build, install, grant, then test without rebuilding.
  proj="$work/ios"
  mkdir -p "$proj/LibraryTests.xcodeproj/xcshareddata/xcschemes" "$proj/HostApp" "$proj/LibraryTests"
  cp "$here/Host/project.pbxproj" "$proj/LibraryTests.xcodeproj/"
  cp "$here/Host/LibraryTests.xcscheme" "$proj/LibraryTests.xcodeproj/xcshareddata/xcschemes/"
  cp "$here/Host/HostApp.swift" "$proj/HostApp/"
  cp "${core_sources[@]}" "$here"/Core/*.swift "$proj/LibraryTests/"
  common=(-project "$proj/LibraryTests.xcodeproj" -scheme LibraryTests -destination "id=$udid" -derivedDataPath "$work/dd")
  xcodebuild build-for-testing "${common[@]}" > "$work/build.log" 2>&1 || { tail -40 "$work/build.log"; exit 1; }
  app="$(find "$work/dd/Build/Products" -maxdepth 2 -name HostApp.app -type d | head -1)"
  xcrun simctl install "$udid" "$app"
  xcrun simctl privacy "$udid" grant photos com.vecvel.danaview.librarytests
  # `simctl privacy grant photos` (Xcode 26) writes a version-1 entry, which the `.readWrite`
  # authorization query (version 2) of iOS 14+ reports as not determined. Mark this throwaway test
  # host's entry, in this simulator's own TCC store only, as the version a user's "Allow Full
  # Access" writes.
  tcc_db="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/TCC/TCC.db"
  sqlite3 "$tcc_db" "update access set auth_version = 2 where service = 'kTCCServicePhotos' and client = 'com.vecvel.danaview.librarytests'"
  (xcodebuild test-without-building "${common[@]}" -parallel-testing-enabled NO 2>&1) > "$work/test.log" || true
  grep -E "Test Case.*(passed|failed|skipped)|error:|Executed|TEST (EXECUTE )?(SUCCEEDED|FAILED)" "$work/test.log" || true
  [ -n "${DV_KEEP:-}" ] && { echo "kept $work"; trap - EXIT; }
  xcrun simctl uninstall "$udid" com.vecvel.danaview.librarytests || true
  if grep -qE "TEST (EXECUTE )?SUCCEEDED" "$work/test.log"; then exit 0; fi
  tail -60 "$work/test.log"
  exit 1
fi

echo "unknown mode $mode (macos | ios <udid>)" >&2
exit 2
