# Editor build hand-off: Mac + Windows

From 2026-10-10 the video editor is built on two machines at once. The Mac has only 8 GB RAM. Running the Android emulator, the iOS simulator and Xcode builds together overloaded it, so the Android work moves to a 32 GB Windows laptop.

| Machine | Builds | Branch |
|---|---|---|
| **Mac** (Xcode 26.6) | Everything except the Android lane: editor core, editor screens, integration, QA, all iOS work, ENG-01..07, ENG-09, ENG-02/03/04, ENG-06, AI-05. It also finishes the two engine spikes, IOS-01 and AND-01. | `editor-wip` |
| **Windows laptop** (32 GB, no Xcode) | The Android lane: ENG-08 and AI-04 first, then AND-02..AND-17 (18 tickets). | `editor-android` |

Windows can't build or test iOS: Xcode only runs on macOS.

## Files in this folder

| File | What it is |
|---|---|
| [ANDROID_LANE.md](ANDROID_LANE.md) | The Windows ticket plan: order, gates, owned files, verification, conflict hot-spots |
| [WINDOWS_SETUP.md](WINDOWS_SETUP.md) | Installing the toolchain on Windows, cloning without line-ending damage, smoke checks, known Windows pitfalls |
| [BUILD_STATE.md](BUILD_STATE.md) | Status of all 158 tickets, plus the notes, deferrals and hand-off facts from every finished builder |
| [android_lane_workflow.js](android_lane_workflow.js) | The builder workflow the Windows Claude session runs for the Android lane |
| [claude-memory/](claude-memory/) | A copy of Claude's project notes, so the Windows session knows the rules and history |
| [../../../tool/handoff/install_claude_memory.ps1](../../../tool/handoff/install_claude_memory.ps1) | Installs those notes into Claude's folder on Windows |

## Owner checklist (Windows laptop)

1. Follow [WINDOWS_SETUP.md](WINDOWS_SETUP.md) up to and including its smoke checks. That covers installing the tools, setting Git to keep LF line endings, cloning, and creating the `editor-android` branch.
2. Copy `android/key.properties` and `android/app/release.jks` from the Mac by USB. Never commit or email them.
3. Install the Claude desktop app and sign in with the same account. Open the `vwish_player` folder once in the Code tab, then close that session.
4. In PowerShell, from the repo folder:
   ```powershell
   powershell -ExecutionPolicy Bypass -File tool\handoff\install_claude_memory.ps1
   ```
5. Start a new Code session in the `vwish_player` folder and paste the first message below.

Both machines share one Claude usage limit. The split removes the memory bottleneck, not the usage limit.

## First message for Claude on Windows

```
You are the Windows Android-lane builder for the Vwish video editor.
Read docs/editor/handoff/README.md, ANDROID_LANE.md, WINDOWS_SETUP.md and BUILD_STATE.md first.
Run the smoke checks from WINDOWS_SETUP.md and fix anything missing in the toolchain (tell me before installing anything).
Then build the lane tickets whose gates are met, using docs/editor/handoff/android_lane_workflow.js
(args: root = this repo path with forward slashes, landed = the Mac tickets already on editor-wip).
Work on branch editor-android; commit each finished ticket as "feat(editor): <TICKET> <title>" with no co-author trailer and push.
Tell me after each ticket lands so the Mac can merge it. Use a workflow for the build.
```

## How the two machines stay in sync

- **Windows:**
  - Commits one ticket at a time to `editor-android` and pushes.
  - Only edits files its tickets own (BUILD_PLAN §2/§7).
  - Files on the shared-file register (§7) get small, targeted insertions.
- **Mac:**
  - When the owner says a Windows ticket landed, the Mac session merges `origin/editor-android` into `editor-wip`.
  - The Mac pushes `editor-wip` after each batch of finished tickets.
- **Getting Mac work onto Windows:** before starting a gated ticket, run:
  ```bash
  git fetch origin
  ```
  ```bash
  git merge origin/editor-wip
  ```
- **Gates between the machines:**

  | Gate | Built on | Unblocks |
  |---|---|---|
  | ENG-06 (spike results folded in, Pigeon surface frozen) | Mac | AND-02 onward (Windows) |
  | ENG-09 (example host app) | Mac, done | ENG-08 (Windows) |
  | ENG-08 (Android plugin glue) | Windows | ENG-06 (Mac) |
  | API-04 | Mac, done | AND-09 |
  | ENG-02 | Mac | AND-10 |
  | ENG-03 | Mac | AND-13, AND-14, AND-15 |
  | ENG-04 | Mac | AND-11 |

  ENG-08 and AI-04 can start as soon as the Windows toolchain works. ENG-08 first: the Mac's ENG-06, and through it every native ticket on both phones, waits for it.
- **Line endings:** `.gitattributes` keeps every text file LF on all machines. Test fixtures, goldens and vectors are marked `-text` so they stay byte-for-byte; some subtitle and LUT fixtures contain CR on purpose.

## Rules that apply on both machines

- **Sources of truth:** `docs/editor/ARCHITECTURE.md` (decisions D-1..D-44) and `docs/editor/BUILD_PLAN.md`.
- **Owner defaults (D-43, revisable):**
  - iOS 15.0 target.
  - Android editor gate: API 29 + GLES3 + 2 GB.
  - No auto captions on armeabi-v7a.
  - Android editor data excluded from backup.
  - No MKV/WebM remux on iOS.
- **Downloads:** only normal pub/Gradle/CocoaPods dependency resolution. Never download speech models or media; generate test media locally with ffmpeg.
- **Device-only checks:** recorded as "deferred: no device available", never faked.
- **Commits:** no Claude co-author trailer.
- **Builders** never run state-changing git commands; the session lead commits.
