<!-- OWNER: QA-10 -->

# QA-10 · Persistence, crash recovery and media-access survival

This report covers BUILD_PLAN QA-10 (M6): journal crash recovery, the corrupt-file restore paths, D-12 read-only and blocked projects, iOS bookmarks (V-D3) and Android URI grants (V-D2) across restarts, reinstalling over the top, backup exclusion (V-D4, V-A7), fsync (V-D1), and the D-44 rule that originals stay untouched after a full editing session.

## Suite

| Path | What it is |
|---|---|
| `integration_test/editor_store/qa10_store_test.dart` | The three phases (`seed`, `edit`, `verify`). It uses the real app wiring and the production engine through QA-00's `E2eApp` and `E2eEditor` (integration_test/editor/support). |
| `integration_test/editor_store/support/qa10.dart` | Media layout, typed host requests, the fsync probe (dart:ffi), and store helpers (corrupt a body, mark a header as newer). |
| `integration_test/editor_store/tool/qa10_host.py` | Host driver. It uninstalls the app for a clean start, runs the phases, and serves the QA-00 file handshake (`kill`, `screenshot`, `backupAttrs`, `compareOriginals`). It also takes the baseline snapshot of the originals and builds and injects the fsync probe. |
| `integration_test/editor_store/tool/fsync_probe.c` | A dylib that interposes `fsync(2)` (dyld `__interpose`). It counts the calls and records the path of each descriptor (`F_GETPATH`). |
| `integration_test/editor_store/tool/android_backup_check.sh` | V-A7, the `bmgr` procedure. It also has an optional strace for V-D1 on Android. Windows lane. |

```sh
# iOS Simulator (this Mac)
python3 -I integration_test/editor_store/tool/qa10_host.py -p ios -d <udid> run          # seed, edit, verify
# Android (Windows lane)
python3 -I integration_test/editor_store/tool/qa10_host.py -p android -d emulator-5554 run
integration_test/editor_store/tool/android_backup_check.sh -d emulator-5554 [-s]
```

Evidence lands in `build/qa10/<platform>/<device>/`:

- `logs/qa10-{seed,edit,verify}.log`: the `DV_QA10 <check>: <result>` lines.
- `logs/host.log`
- `screens/`
- `baseline.json`, `after.json`, `compare.json`: the D-44 snapshot of the originals.
- `backup-attrs.json`: V-D4.
- `summary.txt`

### Phases

1. **seed** (ends in a host kill). The app boots, then the originals are copied to `Documents/qa10/{originals,relink}`. The host keeps two more originals outside the container (`host/originals/tone_under_video.mp4` and `host/scratch/clap_flash_av.mp4`), which are iOS Files picks. After the kill, the host snapshots every original under Documents and the host originals: size, SHA-256, mtime (ns) and every xattr. It also records the mtime and xattrs of each folder that holds an original.
2. **edit** (ends in a host kill with the editor open).
   - Projects › New project › Files builds the session project from the originals. The Documents files become `AppRelativeLocator(documents)` and the outside files become `BookmarkLocator`. The bookmark's stat and quickHash are recorded.
   - Text, then a manual save, then a second text edit that only the autosave journal holds.
   - Store fixtures for the next launch:
     - A Photos-route managed copy (this creates and excludes `media/` and `derived/`).
     - A project with a corrupt main and a valid `.bak`.
     - A project with every copy corrupt and a valid journal.
     - A schema-2/minReader-1 document (read-only).
     - A schema-2/minReader-2 document (blocked).
3. **verify**. `flutter test` reinstalls the app over the top and launches it. The checks are listed below. A full session follows (export with "Keep a copy", relink, delete every project, GC), then the host compares the originals with the baseline.

## Results: iOS Simulator, 2026-10-16

The run used the **iPhone 16 simulator (iOS 26.5)** (`6663101E-6BE7-47D4-B3B8-055700BF2E02`), with Xcode 26.6, Flutter 3.44 and a debug build. The command was `qa10_host.py -p ios -d 6663101E-… run`. All three phases passed: **seed pass, edit pass, verify pass (6/6)**.

| Check | Result | Evidence |
|---|---|---|
| Crash recovery after a forced kill (journal) | **pass** | Kill with the editor open: `simctl terminate` while the journal was ahead. On relaunch, `recoverable()` reported journal rev 9 > main rev 8. The Projects banner "Unsaved changes found" › Restore restored the journal-only text `QA10 JOURNAL …`. Screens: `qa10_before_kill`, `qa10_recovery_offer` |
| Reinstall over the top → zero missing media | **pass** | The data container path **changed** on reinstall: `…/18B82397…` before, `…/C89F55FE…` after (the simulator also moves the container). All 4 assets were online in the media health report, and every locator stat'ed. Documents references re-resolve against the new container. |
| iOS Files bookmark survives restart + reinstall (V-D3) | **pass** | The bookmark made in `edit` resolved in `verify` after the kill and the reinstall, with the same size (914 351 B) and quickHash `c41b4d56…`. The bookmark was created through `MediaAccess.persist` on a file outside the container (the Files in-place route). The real document picker is a device item (below). |
| Corrupt main, valid `.bak` | **pass** | Open read the `.bak` (1 marker). The main file was byte-, size- and mtime-identical after open, so opening never wrote. The next save rewrote a valid main. |
| Every copy corrupt, journal valid ("Restore last good version") | **pass** | Open → `StoreFailure(corrupt)`. `recoverable()` offered the project. The Projects banner › Restore promoted the journal (2 markers), and a fresh open of the promoted main is valid. Screen: `qa10_projects_corrupt_recovery` |
| D-12 newer schema read-only | **pass** | Summary `readOnlyNewer` and card "Read-only". `open().readOnly`. `save` → `StoreFailure(newerSchema)`. The editor shows the "Read-only: made with a newer Danaview" banner. The file was not written by the API or the editor. Screens: `qa10_projects_newer_blocked`, `qa10_read_only_newer` |
| D-12 newer minReader blocked | **pass** | Summary `needsNewerApp` and card "Needs update". `open` → `StoreFailure(newerSchema)`, and the file was not written. |
| Backup exclusion read-back (V-D4) | **pass** | Host `xattr -p com.apple.metadata:com_apple_backup_excludeItem`: `media/` and `derived/` = `com.apple.MobileBackup` (excluded). `projects/`, `danaview/editor` and `Documents` have no attribute (backed up). The app log also shows `kExcludedFromBackupXattrName set on path`. `danaview/speech` did not exist in this run because no speech model was installed (AI-09's exclusion is not exercised here). |
| fsync (V-D1) | **pass** | With the probe injected: `RandomAccessFile.flush()` (`LocalStoreFs.writeBytesSynced`) issued 1 `fsync(2)` on the written file. A real project save issued 3 `fsync(2)`, including `…/projects/<id>/project.dnproj.tmp-<rand>` *before* the rename. `F_FULLFSYNC` is not used by Dart, which is the caveat ARCH §8.3 already designs around (checksummed format + tmp/.bak fallbacks). |
| Full session: export with "Keep a copy" | **pass** | 720p H.264 export. The copy was written as a new file `Documents/Exports/QA10 session <n>.mp4` (4.37 MB) through `DocumentsExportWriter`. |
| Full session: relink | **pass** | The bookmarked scratch file was deleted. The Missing media flow (`RelinkController.stage` + `apply`) relinked it to `Documents/qa10/relink/clap_flash_av.mp4` (a documents reference). |
| Full session: project delete + GC | **pass** | All 6 bundles were deleted, with none left. `GcReport(swept, deleted 0, released 0, kept 1)`: the managed copy is younger than the GC grace period, so it is kept by design. |
| D-44 originals unchanged | **pass** | 4 originals compared: 3 under Documents and 1 bookmarked host original. Size, SHA-256, mtime and xattrs were unchanged. The file set of every folder holding an original is unchanged, as are the folders' mtime and xattrs. The only new file under Documents was the kept export copy, in `Exports/`. |

One finding from the run (not a failure, since it is by design): the Projects scan reads headers only. A project whose bodies are all corrupt therefore shows health `ok` on its card, with the recovery flag, until it is opened. Opening reports `corrupt`, and the banner offers the restore.

### Simulator realities and notes

- An interposed `fcntl` (the first probe build) stopped `flutter test` from ever attaching to the app. The probe now interposes `fsync` only.
- On the simulator, `flutter test` keeps the app installed between phases only because the host kills the app first (the same mechanism as QA-00's s09). The verify phase then uninstalls it at the end, after the evidence is collected.

## Deferred

| Item | Status | How |
|---|---|---|
| Physical iPhone: reinstall over the top with a new container UUID, bookmark from the real document picker (V-D3), `xattr`/iCloud backup size (V-D4), fsync and kill -9 during autosave | **deferred: no device available** | `qa10_host.py` drives the simulator only. On a device, run the same test file with `flutter test -d <device>` per phase, kill from Xcode, reinstall with `xcrun devicectl device install app`, then confirm the backup size in Settings › iCloud. |
| Android emulator: all phases (journal recovery, corrupt paths, D-12, D-44 snapshot through `run-as`) | **deferred: Windows lane** | `python3 -I integration_test/editor_store/tool/qa10_host.py -p android -d emulator-5554 run` |
| Android persisted URI grant survives a restart (V-D2) | **deferred: Windows lane** | Needs a Photo Picker/SAF grant: pick through the real picker (manual or uiautomator), then `am force-stop`, relaunch, and check that the project shows no missing media. The test leaves external media out on Android (`Qa10Config.hasHostMedia`). |
| Android `bmgr` procedure: editor and speech trees excluded (V-A7) | **deferred: Windows lane** | `integration_test/editor_store/tool/android_backup_check.sh -d emulator-5554`. Statically, both rule files exclude `danaview/editor` and `danaview/speech` (cloud backup and device transfer), and the manifest references both. |
| Android fsync evidence (V-D1) | **deferred: Windows lane** | `android_backup_check.sh -d emulator-5554 -s` (strace on a userdebug/emulator image during an autosave) |
| Physical Android device: reinstall, grant, bmgr | **deferred: no device available** | Same scripts on a device (the archive listing needs root and is skipped there). |
