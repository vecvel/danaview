---
name: video-editor-build
description: "State and rules of the in-progress Vwish video editor build (docs, owner decisions, workflow approach, pending permissions)"
metadata:
  node_type: memory
  type: project
  originSessionId: 82e4ea82-570a-4648-b8b8-8e1276338981
  modified: 2026-10-10T13:24:39.255Z
---

The owner (2026-10-07) asked for a full CapCut-class video editor shipped in ONE release: iOS + Android first, native engines (AVFoundation/Core Image, Media3), on-device whisper.cpp AI subtitles. Desktop editor later.

- Source of truth: `docs/editor/ARCHITECTURE.md` (decisions D-1..D-45) and `docs/editor/BUILD_PLAN.md` (164 tickets, milestones M0–M6, §8 feature coverage).
- Defaults applied 2026-10-08 because the owner skipped the sign-off questions (revisable; D-43): iOS target 15.0, Android editor API 29+/GLES3/2 GB, no auto captions on armeabi-v7a, Android editor data excluded from backup, no MKV/WebM remux on iOS, iOS 15/16 checked by compile-time guards only (no lab devices).
- 2026-10-08: the owner approved downloading whisper.cpp v1.9.4 from github.com/ggml-org/whisper.cpp (AI-01, vendored into packages/vwish_whisper). Speech models are still downloaded at runtime only, with in-app user consent.
- Build rounds run as workflows with dependency-ordered ticket groups, resume-aware prompts, Opus for native/complex and Sonnet for mechanical tickets, one review + fix per round. Session limits interrupt often.

A `resumeFromRunId` resume only reuses results up to the first unfinished agent() call, so finished groups that come after it run again. To continue a round, use a copy of the script with a PRELOADED map of finished group results taken from the journal, as in `workflows/scripts/editor-build-m0-m1-continue.js` (run wf_f061831b-584, started 2026-10-10).

2026-10-10: the owner turned down a demo/preview build. They want the full working editor as soon as possible.
- A second lane, run wf_566f2fcd-2f2 (CORE-22/23/24/30, AI-09..12, AI-03), runs in parallel, limited to pure Dart and host C++ work.
- Once both lanes finish, launch one rolling workflow over all remaining tickets (M2–M6) with PRELOADED results, so work doesn't stop between rounds.
- The Mac has 8 GB RAM, so don't run Gradle/Xcode/emulator-heavy groups side by side.
- The Android SDK's CMake 3.22.1 + Ninja are at ~/Library/Android/sdk/cmake/3.22.1/bin, so no CMake download is needed.
- UX-42 conflicts with the owner's removal of the licences/About row: when it's built, do the privacy/terms update only. 2026-10-10: the owner said not to run auto-resume. Don't schedule CronCreate resume jobs; resume only when they ask.

**Why:** the owner wants production-ready results as soon as possible while their usage quota is the bottleneck.
**How to apply:** continue from the latest workflow journal; never redo finished work; report progress plainly (owner checks "how much done" often).

2026-10-10, 20:30:
- Branch `editor-wip` is pushed to github.com/vecvel/vwish. It holds a snapshot of the uncommitted work; `main` is unchanged.
- Both lanes now run as one: `workflows/scripts/editor-build-continue-2.js`, run wf_d3beb658-533. Its PRELOADED map is merged from the journals of wf_615dbb40-de2, wf_f061831b-584 and wf_566f2fcd-2f2.
- 20:40: replaced by `workflows/scripts/editor-build-m1-m2.js` (run wf_09f7e5c6-463), covering ALL remaining M1 + M2 tickets. Its PRELOADED map is merged from journals of runs wf_615dbb40-de2, wf_f061831b-584, wf_566f2fcd-2f2 and wf_d3beb658-533. M3 is next.
