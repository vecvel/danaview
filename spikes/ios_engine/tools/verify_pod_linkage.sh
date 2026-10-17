#!/usr/bin/env bash
# IOS-01 spike (V-N9): prove the prebuilt `-fcikernel` metallibs ship correctly from the pod for
# every CocoaPods linkage the app may use, for the simulator AND for a device (arm64 iphoneos,
# unsigned build). Works on a throwaway copy of the spike so the main checkout's Pods/ stay intact.
#
# Usage: tools/verify_pod_linkage.sh [workdir]
# For each linkage in {library (static libs, no use_frameworks!), static (use_frameworks!
# :linkage => :static), dynamic (use_frameworks!)} it regenerates the project, builds the host app
# for iphonesimulator and iphoneos (CODE_SIGNING_ALLOWED=NO) and reports where the metallib
# landed inside the .app.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$(mktemp -d)}"
mkdir -p "$WORK"
echo "workdir: $WORK"
for LINKAGE in library static dynamic; do
  DIR="$WORK/$LINKAGE"
  rm -rf "$DIR"
  mkdir -p "$DIR"
  rsync -a --exclude build --exclude results --exclude Pods --exclude 'DVSpikeHost.xcworkspace' \
    --exclude 'DVSpikeHost.xcodeproj' --exclude flutter_texture_latency "$HERE/" "$DIR/"
  (cd "$DIR" && DV_SPIKE_LINKAGE="$LINKAGE" tools/bootstrap.sh > "$DIR/bootstrap.log" 2>&1)
  for SDK in iphonesimulator iphoneos; do
    DEST="generic/platform=iOS Simulator"
    [[ "$SDK" == iphoneos ]] && DEST="generic/platform=iOS"
    if (cd "$DIR" && xcodebuild -workspace DVSpikeHost.xcworkspace -scheme DVSpikeHost -configuration Release \
        -destination "$DEST" -derivedDataPath "$DIR/dd" CODE_SIGNING_ALLOWED=NO build > "$DIR/build-$SDK.log" 2>&1); then
      APP="$DIR/dd/Build/Products/Release-$SDK/DVSpikeHost.app"
      LIBS=$(cd "$APP" && find . -name 'dv_spike_kernels.*.metallib' | sort | tr '\n' ' ')
      echo "$LINKAGE $SDK: BUILD OK; metallibs in app: $LIBS"
    else
      echo "$LINKAGE $SDK: BUILD FAILED"
      grep -E ": error:" "$DIR/build-$SDK.log" | sort -u | head -5
    fi
  done
done
