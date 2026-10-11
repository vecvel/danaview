# Editor build hand-off: Mac + Windows

From 2026-10-10 the video editor is built on two machines at once. The Mac has only 8 GB RAM. Running the Android emulator, the iOS simulator and Xcode builds together overloaded it, so the Android work moves to a 32 GB Windows laptop.

| Machine | Builds | Branch |
|---|---|---|
| **Mac** (Xcode 26.6) | Everything except the Android lane: editor core, editor screens, integration, QA, all iOS work, ENG-01..07, ENG-09, ENG-02/03/04, ENG-06, AI-05. It also finishes the two engine spikes, IOS-01 and AND-01. | `editor-wip` |
| **Windows laptop** (32 GB, no Xcode) | The Android lane: ENG-08 and AI-04 first, then AND-02..AND-17, AND-18 and AND-19 (20 tickets; AND-18 and AND-19 added by the owner's D-43(e) decision of 2026-10-11, ARCH D-45). | `editor-android` |

Windows can't build or test iOS: Xcode only runs on macOS.

## Files in this folder

| File | What it is |
|---|---|
| [ANDROID_LANE.md](ANDROID_LANE.md) | The Windows ticket plan: order, gates, owned files, verification, conflict hot-spots |
| [WINDOWS_SETUP.md](WINDOWS_SETUP.md) | Installing the toolchain on Windows, cloning without line-ending damage, smoke checks, known Windows pitfalls |
| [BUILD_STATE.md](BUILD_STATE.md) | Status of all 166 tickets, plus the notes, deferrals and hand-off facts from every finished builder |
| [android_lane_workflow.js](android_lane_workflow.js) | The builder workflow the Windows Claude session runs for the Android lane |
| [claude-memory/](claude-memory/) | A copy of Claude's project notes, so the Windows session knows the rules and history |
| [../../../tool/handoff/install_claude_memory.ps1](../../../tool/handoff/install_claude_memory.ps1) | Installs those notes into Claude's folder on Windows |

## Owner checklist (Windows laptop)

1. Follow [WINDOWS_SETUP.md](WINDOWS_SETUP.md) Part A (A1–A8). That covers installing the tools and the Claude app, setting Git to keep LF line endings, cloning to `C:\dev\danaview`, creating the `editor-android` branch and installing Claude's notes. The signing files (A7) are optional: lane work doesn't need them.
2. Start a new Code session in `C:\dev\danaview` and paste the first message below. Claude runs the smoke checks (Part B) and tells you if anything is missing.

Both machines share one Claude usage limit. The split removes the memory bottleneck, not the usage limit.

## First message for Claude on Windows

```
You are the Windows Android-lane builder for the Danaview video editor.
Read docs/editor/handoff/README.md, ANDROID_LANE.md, WINDOWS_SETUP.md and BUILD_STATE.md first.
Run the smoke checks (WINDOWS_SETUP.md Part B) and fix anything missing in the toolchain (tell me before installing anything).
Then build the lane tickets whose gates are met, using docs/editor/handoff/android_lane_workflow.js
(args: root = 'C:/dev/danaview', landed = ['ENG-09', 'API-04'] plus any of ENG-06, ENG-02, ENG-03, ENG-04 I tell you have landed).
Work on branch editor-android; commit each finished ticket as "feat(editor): <TICKET> <title>" with no co-author trailer and push.
Tell me after each ticket lands so the Mac can merge it. Use a workflow for the build.
```

## How the two machines stay in sync

- **Windows:**
  - Commits one ticket at a time to `editor-android` and pushes.
  - Edits only the files its tickets own (BUILD_PLAN §6) and placeholders headed `// OWNER: <ticket>`.
  - The only shared-file register (§7) files it touches are ENG-08's own (Gradle, manifest, plugin class, glue, `lint.xml`), and only inside ENG-08.
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
  | JNI shim set up by ENG-06 (the D-43e sign-off is done: owner decision 2026-10-11) | Mac | AND-16 |
  | AND-16 | Windows | AND-18 |
  | AND-11 | Windows | AND-19 |
  | INT-06 ([INTEGRATION] engine interface additions for render preview: `renderPreview`, `setRenderedRanges`, `powerState`; ARCH D-45) | Mac | AND-18 (Windows; AND-18 waits for both AND-16 and INT-06) |

  ENG-08 and AI-04 can start as soon as the Windows toolchain works. ENG-08 first: the Mac's ENG-06, and through it every native ticket on both phones, waits for it.
- **Line endings:** `.gitattributes` keeps every text file LF on all machines. Test fixtures, goldens and vectors are marked `-text` so they stay byte-for-byte; some subtitle and LUT fixtures contain CR on purpose.

## Rules that apply on both machines

- **Sources of truth:** `docs/editor/ARCHITECTURE.md` (decisions D-1..D-45) and `docs/editor/BUILD_PLAN.md`.
- **Owner defaults (D-43, revisable):**
  - iOS 15.0 target.
  - Android editor gate: API 29 + GLES3 + 2 GB.
  - No auto captions on armeabi-v7a.
  - Android editor data excluded from backup.
  - No MKV/WebM remux on iOS.
- **Owner decision D-43(e), 2026-10-11 (signed off; ARCH D-43, D-45):** preview adapts to the device, export is always full quality and never refused (only slower on weak devices). Proxies on by default on the minimal and low tiers; adaptive preview quality unless pinned; layers over the live decode budget show paused-exact stills during playback only; exact seek may be +30% on AND-16; drop a frame rather than show a late or wrong one; `maxVisualSequences` limits live preview only, and above the decoder limit export runs a multi-pass precompose (AND-19, IOS-20); a render-preview cache for heavy ranges (CORE-37, UX-44, AND-18, IOS-19).
- **Downloads:** only normal pub/Gradle/CocoaPods dependency resolution. Never download speech models or media; generate test media locally with ffmpeg.
- **Device-only checks:** recorded as "deferred: no device available", never faked.
- **Commits:** no Claude co-author trailer.
- **Builders** never run state-changing git commands; the session lead commits.
