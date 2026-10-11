#!/usr/bin/env bash
# IOS-01 / V-N23: build flutter_texture_latency for the simulator, run it once and collect the
# `DVSPIKE-METRIC` lines into results/<label>.texture_latency.jsonl.
# Usage: tools/run_texture_latency.sh <simulator-udid> <label>
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
UDID="$1"; LABEL="$2"
APP="$HERE/flutter_texture_latency"
mkdir -p "$HERE/results"
# Add LatencyProbe.swift to the Runner target and raise the deployment target to 15.0
# (idempotent; uses the xcodeproj gem bundled with CocoaPods, like tools/bootstrap.sh).
POD_BIN="$(command -v pod)"
GEM_HOME_DIR="$(sed -n 's/^GEM_HOME="\([^"]*\)".*/\1/p' "$POD_BIN" | head -1)"
RUBY_BIN="$(head -1 "$GEM_HOME_DIR/bin/pod" | sed 's/^#!//')"
GEM_HOME="$GEM_HOME_DIR" "$RUBY_BIN" -e '
  require "xcodeproj"
  p = Xcodeproj::Project.open(ARGV[0])
  t = p.targets.find { |x| x.name == "Runner" }
  g = p.main_group.find_subpath("Runner", false)
  unless t.source_build_phase.files_references.any? { |f| f.path == "LatencyProbe.swift" }
    t.source_build_phase.add_file_reference(g.new_reference("LatencyProbe.swift"))
  end
  p.build_configurations.each { |c| c.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0" }
  t.build_configurations.each { |c| c.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0" }
  p.save
' "$APP/ios/Runner.xcodeproj"
cd "$APP"
flutter build ios --simulator --debug --no-codesign > "$HERE/results/$LABEL.texture_latency.build.log" 2>&1 \
  || { tail -30 "$HERE/results/$LABEL.texture_latency.build.log"; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" build/ios/iphonesimulator/Runner.app
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' build/ios/iphonesimulator/Runner.app/Info.plist)
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
LOG="$HERE/results/$LABEL.texture_latency.log"
# --console-pty streams stdout; the app exits itself after the last phase.
perl -e 'alarm shift; exec @ARGV' 240 xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE" > "$LOG" 2>&1 || true
grep -o 'DVSPIKE-METRIC {.*}' "$LOG" | sed 's/^DVSPIKE-METRIC //' > "$HERE/results/$LABEL.texture_latency.jsonl" || true
cat "$HERE/results/$LABEL.texture_latency.jsonl"
