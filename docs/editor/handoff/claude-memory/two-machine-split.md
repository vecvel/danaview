---
name: two-machine-split
description: "Editor build is split: Mac (iOS + everything else) and a 32 GB Windows laptop (Android lane); git branches and gates"
metadata:
  node_type: memory
  type: project
  originSessionId: 82e4ea82-570a-4648-b8b8-8e1276338981
  modified: 2026-10-10T17:26:43.876Z
---

On 2026-10-10 the owner split the video editor build across two machines because the Mac has only 8 GB RAM.

- **Mac:** this repo at /Users/besaoct/Desktop/danaview. It does everything except the Android lane:
  - core, UI/UX, integration and QA
  - all iOS work
  - ENG-01..07, ENG-09, ENG-02/03/04, ENG-06 (integration freeze), AI-05
  - finishing the IOS-01 and AND-01 spikes
- **Windows laptop (32 GB, no Xcode):** the Android lane:
  - ENG-08 (Android plugin glue; moved back to Windows 2026-10-11 because the Mac emulator is out of storage and the Mac queue had it behind ENG-07) and AI-04
  - AND-02..AND-07 (M2), AND-08/09/17/10/16 (M3), AND-11/13/14/15 (M4), AND-12 (M5)
- **Hand-off docs:** in the repo at docs/editor/handoff/ (README, ANDROID_LANE.md, WINDOWS_SETUP.md, BUILD_STATE.md, android_lane_workflow.js, plus a copy of these notes under claude-memory/).
- **Git:**
  - Mac work goes to branch `editor-wip`.
  - Windows works on `editor-android`, branched from editor-wip, with one commit per ticket.
  - The Mac session merges editor-android into editor-wip, and Windows merges editor-wip back to receive gates.
- **Gates:** ENG-08 (Windows) must land before ENG-06 (Mac), and ENG-06 must land before AND-02+. Other Mac-side deps are API-04 (done), ENG-02, ENG-03 and ENG-04. ENG-09 (done) gates ENG-08. AI-04 has no Mac gate.
- `.gitattributes` keeps LF everywhere and marks test fixtures `-text` (some SRT/LUT fixtures contain CR on purpose).

**Why:** emulator + simulator + Xcode at once overloads 8 GB, so tests time out and get rerun, wasting usage.
**How to apply:**
- Never let a Mac builder take an Android-lane ticket.
- When the owner says Windows pushed a ticket, merge editor-android into editor-wip and continue the gated Mac tickets.

See [[video-editor-build]] and [[no-claude-coauthor]].
