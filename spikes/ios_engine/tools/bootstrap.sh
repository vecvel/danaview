#!/usr/bin/env bash
# IOS-01 spike: (re)generate the Xcode project and integrate the local pods.
# Usage: tools/bootstrap.sh            # static-library linkage (default)
#        DV_SPIKE_LINKAGE=dynamic tools/bootstrap.sh
set -euo pipefail
export LANG=en_US.UTF-8
HERE="$(cd "$(dirname "$0")/.." && pwd)"
POD_BIN="$(command -v pod)"
# The xcodeproj gem ships with CocoaPods; reuse its GEM_HOME and Ruby.
GEM_HOME_DIR="$(sed -n 's/^GEM_HOME="\([^"]*\)".*/\1/p' "$POD_BIN" | head -1)"
RUBY_BIN="$(head -1 "$GEM_HOME_DIR/bin/pod" | sed 's/^#!//')"
GEM_HOME="$GEM_HOME_DIR" "$RUBY_BIN" "$HERE/tools/generate_project.rb"
cd "$HERE"
pod install --no-repo-update
