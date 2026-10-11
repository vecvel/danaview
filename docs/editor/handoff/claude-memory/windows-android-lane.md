---
name: windows-android-lane
description: "This machine is the Windows laptop that builds the editor's Android lane; how to work, sync and report"
metadata:
  type: project
---

This machine is the **Windows laptop (32 GB RAM, no Xcode)** in the two-machine editor build ([[two-machine-split]]). It builds only the Android lane:
- ENG-08 (most urgent: it gates the Mac's ENG-06) and AI-04
- AND-02..AND-07 (M2)
- AND-08, AND-09, AND-17, AND-10, AND-16 (M3)
- AND-11, AND-13, AND-14, AND-15, AND-18 (render-preview renderer, after AND-16), AND-19 (multi-pass export precompose, after AND-11) (M4)
- AND-12 (M5)

It never takes iOS, core, UX, integration or QA tickets; the Mac does those.

- **Read first:** the hand-off docs in the repo:
  - docs/editor/handoff/README.md
  - ANDROID_LANE.md (ticket order, gates, owned files)
  - WINDOWS_SETUP.md (toolchain and pitfalls)
  - BUILD_STATE.md (what's done)
  - android_lane_workflow.js (builder workflow; pass `args.root` and `args.landed`)
- **Git:**
  - Work on branch `editor-android`, branched from `editor-wip`.
  - One commit per finished ticket: `feat(editor): <TICKET> <title>`, with NO Claude co-author trailer ([[no-claude-coauthor]]).
  - Push after each ticket.
  - To receive Mac gates (ENG-06, ENG-02/03/04), run `git fetch` then `git merge origin/editor-wip`. ENG-09 and API-04 are already done.
- **Gates:**
  - ENG-08 and AI-04 can start immediately (ENG-09 is already on editor-wip).
  - AND-02+ start when ENG-06 is on editor-wip. AND-16 also needs ENG-06's JNI-shim setup (the owner signed D-43e on 2026-10-11, so there is no sign-off wait). AND-18 starts after AND-16, AND-19 after AND-11.
  - Tell the owner which ticket landed so the Mac session can merge it.
- **Owner decision D-43(e), 2026-10-11 (ARCH D-43, D-45):** preview adapts to the device; export is always full quality and never refused. Proxies on by default on minimal/low; adaptive preview quality unless pinned; layers over the live budget show paused-exact stills during playback only; exact seek up to +30% on AND-16; drop frames, never show late or wrong ones; `maxVisualSequences` limits live preview only and export above the decoder limit runs a multi-pass precompose (AND-19); heavy ranges can be pre-rendered (AND-18).
- **Mac-only notes:** the paths and tools in [[video-editor-build]] and [[ios-simulator-testing-quirks]] are Mac-only. On this machine, use the Android SDK's CMake/NDK from local.properties, run .sh scripts in Git Bash, and use the Pixel_9_Pro_XL_API_35 emulator (plus Pixel_API_29, Pixel_API_34 and Pixel_Tablet_API_35 for the tickets that name them, one emulator at a time).
- **Rules carried over from the owner:**
  - Downloads: only normal pub/Gradle dependency resolution. Never download speech models or media; generate fixtures with ffmpeg.
  - Device-only checks are marked "deferred: no device available", never faked.
  - Don't schedule auto-resume jobs.
  - Report progress plainly when the owner asks "how much done".

**Why:** the Mac's 8 GB RAM can't run the Android emulator alongside the iOS simulator and Xcode builds.
**How to apply:** pick the next lane ticket whose gates are met (ANDROID_LANE.md), build it with the lane workflow, verify, commit, push, and tell the owner.
