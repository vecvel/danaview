---
name: ios-simulator-testing-quirks
description: "How to drive and inspect the Vwish Player app in the iOS Simulator reliably (tap duration, parallel calls, VM service eval)"
metadata:
  node_type: memory
  type: reference
  originSessionId: fe655deb-1371-4039-8300-794ec383b6ed
  modified: 2026-10-02T16:21:42.579Z
---

- Simulator `tap` with the default (instant) duration often doesn't register in the Flutter app; pass `duration: 0.1`.
- Never issue a tap and a screenshot in the same parallel tool block — they run concurrently and the screenshot shows the pre-tap state. The player's controls also fade in over ~250 ms.
- A debug build launched via the simulator tool shows a white screen for a few seconds before the first frame.
- VM-service `evaluate` needs the frontend compiler: run `flutter attach -d <udid> --debug-url <vm url from os_log>` in the background first, then use the DDS URL it prints. Read app logs with `xcrun simctl spawn booted log show --predicate 'process == "Runner"'` and grep "(Flutter)".
- mpv on the simulator forces software rendering; mpv `video-rotate` crashes there (see [[vwish-player-architecture]] if written).
