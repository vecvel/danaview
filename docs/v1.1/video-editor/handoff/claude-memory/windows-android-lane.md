---
name: windows-android-lane
description: "This machine is the Windows laptop that builds the editor's Android lane; Danaview repo at C:\dev\danaview, branch editor-android @ 5be9d36, next tickets, resume args, rules"
metadata:
  type: project
  modified: 2026-10-11
---

This machine is the **Windows laptop (32 GB RAM, no Xcode)** in the two-machine editor build ([[two-machine-split]]). It builds only the Android lane: ENG-08, AI-04, AND-02..AND-19. It never takes iOS, core, UX, integration or QA tickets; the Mac does those.

## Identity after the rename (2026-10-11)
- App is **Danaview**. Repo: `C:\dev\danaview` (moved out of OneDrive; no spaces). Packages are `danaview_*` (data, domain, editor, editor_core, editor_engine, editor_engine_api, editor_fonts, engine, features, platform, transcription, ui_kit, whisper). App ID / namespace `com.vecvel.danaview`.
- Branch `editor-android` at `5be9d36` ("chore: drop \"player\" from the project name"), on top of the rename commits `692b448` and the merge `e6efc66`. The rename cutover is DONE ([[danaview-rename]]).
- Verified 2026-10-11: `flutter pub get` passes in root + all 13 packages, `flutter build apk --debug` passes (needs the media_kit jar workaround in [[windows-machine-state]]).

## State
- **Done and merged into editor-wip:** ENG-08, AI-04, AND-02, AND-03, AND-04, AND-05, AND-08.
- **Landed Mac gates:** ENG-09, API-04, ENG-06, ENG-02, ENG-03, ENG-04.
- **Next tickets on resume (owner's order):** AND-06, AND-07, AND-09, then AND-17, AND-10, AND-16, AND-13/14/15, AND-11, AND-18, AND-19, AND-12. (AND-16's design follows [[d43e-signoff]]; its gates are ENG-06 + AND16-SHIM; AND-18 also needs INT-06 from the Mac.)
- **Lane workflow args (owner, 2026-10-11):** `root = 'C:/dev/danaview'`, `landed = ["ENG-09","API-04","ENG-08","AI-04","ENG-06","ENG-02","ENG-03","ENG-04"]`, plus `preloaded` for the done groups (`eng08`, `ai-android`, `and-m2a`, `and-m3-render`). Script: `docs/v1.1/video-editor/handoff/android_lane_workflow.js` (already uses C:/dev/danaview paths).
- Only resume when the owner says so ("continue the editor build"); never start builders or the workflow otherwise.

## How to work
- **Read first:** docs/v1.1/video-editor/handoff/README.md, ANDROID_LANE.md (ticket order, gates, owned files), WINDOWS_SETUP.md, BUILD_STATE.md, android_lane_workflow.js.
- **Git:**
  - Work on `editor-android`; the Mac merges it into `editor-wip`, and this branch pulls `editor-wip` back (`git fetch` then `git merge origin/editor-wip`, or `git pull` when in sync).
  - One commit per finished ticket: `feat(editor): <TICKET> <title>`, NO Claude co-author trailer ([[no-claude-coauthor]]). Continuous backups while builders run: `chore(editor): work-in-progress backup (Android lane)`.
  - Push after each ticket and tell the owner in one line so the Mac can merge.
- **Gates still open:** AND-16 is gated on ENG-06 + `AND16-SHIM`. Do NOT add `AND16-SHIM` to `landed` until the Mac lead confirms `android/src/main/cpp/` exists with the shim (owner, 2026-10-11). AND-18 needs INT-06. `D-43E` is no longer a gate.
- **Machine notes:** source `~/danaview_env.sh` in every Bash command, run .sh scripts in Git Bash, emulators Pixel_9_Pro_XL_API_35 (default), Pixel_API_29 (boot with `-feature GLESDynamicVersion`), Pixel_API_34, Pixel_Tablet_API_35, one at a time. Paths in [[video-editor-build]] and [[ios-simulator-testing-quirks]] are Mac-only.
- **Rules carried over from the owner:**
  - Downloads: only normal pub/Gradle dependency resolution. Never download speech models or media; generate fixtures with ffmpeg.
  - Device-only checks are marked "deferred: no device available", never faked.
  - Don't schedule auto-resume jobs. Don't start workflows or builds when the owner says they are near their usage limit.
  - Report progress plainly when the owner asks "how much done".

**Why:** the Mac's 8 GB RAM can't run the Android emulator alongside the iOS simulator and Xcode builds.
**How to apply:** on resume, read [[android-lane-progress]], pull, then run the lane workflow with the args above; commit, push, and tell the owner after each ticket.
