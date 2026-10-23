#!/usr/bin/env bash
# OWNER: HOM-21
#
# XCTests of the Share Extension inbox (BUILD_PLAN HOM-21) without the Danaview app, in a throwaway
# Swift package assembled in a temporary directory:
#
#   macos    the Flutter-free inbox core (Classes/Inbox/InboxCore.swift) together with the
#            extension's InboxWriter and folder-snapshot parser (ios/DanaviewShare/, Foundation
#            parts): a batch written by the extension round-trips through the plugin's reader;
#            incomplete and stale batches, path escapes, take/delete, snapshots. The Glue's macOS
#            answers (notSupportedOnDevice) are covered by Tests/PhotoLibrary's glue tests.
#   ios      type-checks every plugin source against Flutter.xcframework and the extension
#            sources (UIKit share sheet) for the iOS Simulator SDK; no simulator is booted.
#
# The temporary directory is removed on exit. Usage:
#   packages/danaview_library_native/darwin/Tests/Inbox/run_xctests.sh macos|ios
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
darwin="$(cd "$here/../.." && pwd)"
repo="$(cd "$darwin/../../.." && pwd)"
share="$repo/ios/DanaviewShare"
mode="${1:-macos}"

if [ "$mode" = "ios" ]; then
  flutter_root="${FLUTTER_ROOT:-$(cd "$(dirname "$(command -v flutter)")/.." && pwd)}"
  ios_fw="$flutter_root/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"
  [ -d "$ios_fw/Flutter.framework" ] || { echo "Flutter.framework not found under $ios_fw (run flutter precache --ios)" >&2; exit 1; }
  all_sources=()
  while IFS= read -r f; do all_sources+=("$f"); done < <(find "$darwin/Classes" -name '*.swift' | sort)
  xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios15.0-simulator -F "$ios_fw" \
    -module-name danaview_library_native "${all_sources[@]}"
  xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios15.0-simulator -application-extension \
    -parse-as-library -module-name DanaviewShare "$share"/*.swift
  echo "iOS type-check passed (plugin and DanaviewShare)"
  exit 0
fi

[ "$mode" = "macos" ] || { echo "unknown mode $mode (macos | ios)" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/dv_inbox_xctests.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

mkdir -p "$work/Sources/DanaviewInboxCore" "$work/Tests/DanaviewInboxCoreTests"
for f in "$darwin/Classes/Inbox/InboxCore.swift" "$share/InboxWriter.swift" "$share/FolderPickerView.swift"; do
  ln -s "$f" "$work/Sources/DanaviewInboxCore/$(basename "$f")"
done
for f in "$here"/Core/*.swift; do ln -s "$f" "$work/Tests/DanaviewInboxCoreTests/$(basename "$f")"; done
cat > "$work/Package.swift" <<PKG
// swift-tools-version:5.7
import PackageDescription
let package = Package(
  name: "DanaviewInboxTests",
  platforms: [.macOS(.v11)],
  targets: [
    .target(name: "DanaviewInboxCore"),
    .testTarget(name: "DanaviewInboxCoreTests", dependencies: ["DanaviewInboxCore"]),
  ]
)
PKG
(cd "$work" && swift test 2>&1) > "$work/test.log" || true
grep -E "Test Case.*(passed|failed|skipped)|error:|Executed" "$work/test.log" || tail -40 "$work/test.log"
if grep -q "with 0 failures" "$work/test.log" && ! grep -q "error:" "$work/test.log"; then exit 0; fi
tail -40 "$work/test.log"
exit 1
