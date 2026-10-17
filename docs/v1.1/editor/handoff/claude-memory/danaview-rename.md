---
name: danaview-rename
description: Vwish -> Danaview rename is DONE (2026-10-11); history of the rename tool, what was kept, Windows-only limits
metadata:
  node_type: memory
  type: project
  originSessionId: d0a7a9da-33c4-4eaf-802d-60f31fffee0f
  modified: 2026-10-11T13:48:40.250Z
---

**Cutover done 2026-10-11:** `692b448 chore: rename Vwish to Danaview` and `5be9d36 chore: drop "player" from the project name` are on editor-android; repo now at `C:\dev\danaview`, packages `danaview_*`, app ID `com.vecvel.danaview`. Old "never apply the rename here" notes are obsolete.

History: branch `rename-danaview` (commit 825285e, based on editor-wip ed79da9) holds only `tool/rename/`: `rename_to_danaview.py` (--dry-run/--apply/--regenerate/--verify), README.md (cutover steps for both machines, Mac checklist), DRY_RUN_REPORT.md. Not run on the real tree yet; the Mac runs it at cutover, then `git rm -r tool/rename`.

- Owner decision 2026-10-11: app unpublished, so rename EVERYTHING (IDs, URLs, format ids, prefs, vw_/VW_/Vw/vwt prefixes -> dv), no migration. KEEP only words like WavWriter/vWidth, md_ ids, alphabets, dvwC, the `(vw, vh)` local.
- Windows-only limits: no libclang (ffigen writes a PROVISIONAL mapped file), sprites/metallibs/Podfile.lock regenerate on the Mac only.
- VS Build Tools 2022 (C++ workload) installed on this laptop 2026-10-11 with the owner's OK; `flutter build windows` works now.

**Why:** cutover happens once on the latest editor-wip; the classifier stops on unknown vw tokens.
**How to apply:** if asked to update the tool, rerun the full cycle (apply, regenerate, verify, tests, apk/windows builds, reset and repeat, compare tree hash). Related: [[two-machine-split]], [[windows-machine-state]].
