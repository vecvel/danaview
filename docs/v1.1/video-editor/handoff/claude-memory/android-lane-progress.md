---
name: android-lane-progress
description: "Where the Windows Android lane stands (updated 2026-10-11 after the Danaview rename): branch head, next tickets and run args, open follow-ups, stale helper scripts"
metadata:
  type: project
  modified: 2026-10-11
---

**Head:** `editor-android` at `5be9d36` in `C:\dev\danaview` (Danaview rename landed: `692b448`, `5be9d36`). Done and merged into editor-wip: ENG-08, AI-04, AND-02, AND-03, AND-04, AND-05, AND-08 (merge `e6efc66`). Debug APK builds clean after the rename (2026-10-11).

**Next run (when the owner says to resume; nothing from the Mac needed for the first three):** AND-06, AND-07 (group `and-m2b`), AND-09 (`and-m3-text`), then AND-17, AND-10, AND-16, AND-13/14/15, AND-11, AND-18, AND-19, AND-12.
Args: `root = 'C:/dev/danaview'`, `landed = ["ENG-09","API-04","ENG-08","AI-04","ENG-06","ENG-02","ENG-03","ENG-04"]` (owner-given list, 2026-10-11; `D-43E` is no longer a gate, the workflow dropped it), plus `preloaded` for `eng08`, `ai-android`, `and-m2a`, `and-m3-render` (pass `true`). Before starting: `git fetch && git merge origin/editor-wip`, re-read ANDROID_LANE.md and the workflow script.

**Local workflow copy:** the old patched copy (`android_lane_workflow.local.js`, `patch_wf.js`, `machine_note.txt`) lived in a scratchpad of the old OneDrive-path project and is no longer reachable. On resume, make a fresh local copy of `docs/v1.1/video-editor/handoff/android_lane_workflow.js` with a machine note (source `~/danaview_env.sh`; the media_kit jar workaround in [[windows-machine-state]]).

**Still gated on the Mac:** AND-16 is gated on ENG-06 + `AND16-SHIM`. Do NOT add `AND16-SHIM` to `landed` until the Mac lead confirms `android/src/main/cpp/` exists with the shim (owner, 2026-10-11). AND-18 needs INT-06 (and AND-16's gates).

**Lane follow-ups carried in commit bodies:** API 29 emulator must boot with `-feature GLESDynamicVersion` and `requireGles3=true`; proxy frame loss with production decoders on API 29/35 emulators (QA-04 device check); AND-11/18/19 must install `AudioStreamAssetLoaderFactory` when `Built.selectsAudioStreams`; ENG-09 harness lint+androidTest task dependency defect; ENG-06 BuildConfigTest missing opt-in.

**WIP backup loop (rewritten 2026-10-11):** `~/danaview_wip_commit.sh [tickets]` (one backup of the lane paths in `C:/dev/danaview`: danaview_editor_engine/android/src, danaview_whisper/android, danaview_whisper/src/cmake, danaview_whisper/src/dv_exports.map, scripts/ci/editor; refuses to run off editor-android; skips missing paths; commits `chore(editor): work-in-progress backup (Android lane[: tickets])` and pushes). `~/danaview_wip_loop.sh [tickets]` runs it every 10 min, log `~/danaview_wip_loop.log`, stop with `touch ~/danaview_wip_stop`. Tested by hand (no-op on the real repo, commit path in a scratch clone) and the loop was restarted 2026-10-11 ~20:52 with no ticket label; restart it with the ticket label when builders start. Old vwish_wip_* scripts deleted.

**Why:** sessions get cut by usage limits; this is the resume point.
**How to apply:** read this first, then [[windows-machine-state]] and [[windows-android-lane]].
